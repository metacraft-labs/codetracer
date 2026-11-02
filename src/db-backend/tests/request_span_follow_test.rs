//! Explicit request following keeps replay paging bounded while a real
//! container grows. No mocks: the production DAP handler reads canonical
//! writer fixtures published over one temporary recording path. Paging tests
//! assign handler policy directly; isolated subprocesses also verify the real
//! environment initialization without mutating a running test process.

use std::path::{Path, PathBuf};
use std::sync::mpsc;

use db_backend::dap::{self, DapMessage};
use db_backend::dap_handler::Handler;
use db_backend::db::Db;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::request_spans::LoadRequestSpansArguments;
use db_backend::task::TraceKind;
use serde_json::{Value, json};

fn default_handler(folder: &Path) -> Handler {
    let mut handler = Handler::new(
        TraceKind::Materialized,
        RecreatorArgs::default(),
        Box::new(Db::new(&PathBuf::from(""))),
    );
    handler.set_trace_folder(folder);
    handler
}

fn handler(folder: &Path, follow: bool) -> Handler {
    let mut handler = default_handler(folder);
    handler.follow_request_spans = follow;
    handler
}

fn page(handler: &mut Handler, start: usize, limit: usize) -> Value {
    let arguments = json!({"start": start, "limit": limit});
    let request = dap::Request {
        base: dap::ProtocolMessage {
            seq: 1,
            type_: "request".into(),
        },
        command: "ct/load-request-spans".into(),
        arguments: arguments.clone(),
    };
    let (sender, receiver) = mpsc::channel();
    handler
        .load_request_spans(
            request,
            serde_json::from_value::<LoadRequestSpansArguments>(arguments).expect("arguments"),
            sender,
        )
        .expect("load request spans");
    receiver
        .try_iter()
        .find_map(|message| match message {
            DapMessage::Response(response) => {
                assert!(response.success, "request failed: {response:?}");
                Some(response.body)
            }
            _ => None,
        })
        .expect("handler sent a response")
}

fn publish(folder: &Path, fixture: &str) {
    let source = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/span_stream")
        .join(fixture);
    std::fs::copy(source, folder.join("trace.ct")).expect("publish fixture");
}

#[test]
fn followed_replay_pages_growing_containers_without_claiming_live_controls() {
    let folder = tempfile::tempdir().expect("recording directory");
    publish(folder.path(), "web_session_tail_stage1.ct");
    let mut handler = handler(folder.path(), true);
    let first = page(&mut handler, 0, 1);
    assert_eq!(first["open"], true);
    assert_eq!(first["total"], 5);
    assert_eq!(first["requests"].as_array().expect("page").len(), 1);
    let open_row = page(&mut handler, 4, 1);
    assert_eq!(open_row["requests"][0]["id"], 6);
    assert_eq!(open_row["requests"][0]["isOpen"], true);

    publish(folder.path(), "web_session_tail_stage2.ct");
    let grown = page(&mut handler, 0, 1);
    assert_eq!(grown["open"], true);
    assert_eq!(grown["total"], 7);
    assert_eq!(grown["requests"].as_array().expect("page").len(), 1);
    let settled = page(&mut handler, 4, 1);
    assert_eq!(settled["requests"][0]["id"], 6);
    assert_eq!(settled["requests"][0]["isOpen"], false);
    assert_eq!(settled["requests"][0]["statusCode"], 200);

    handler.follow_request_spans = false;
    assert_eq!(page(&mut handler, 0, 1)["open"], false);
}

#[test]
fn following_an_initially_span_free_container_stays_open_for_future_requests() {
    let folder = tempfile::tempdir().expect("recording directory");
    publish(folder.path(), "no_spans.ct");
    let mut handler = handler(folder.path(), true);
    let empty = page(&mut handler, 0, 1);
    assert_eq!(empty["open"], true);
    assert_eq!(empty["total"], 0);
    assert!(empty["requests"].as_array().expect("page").is_empty());
    publish(folder.path(), "web_session_tail_stage1.ct");
    assert_eq!(page(&mut handler, 0, 1)["total"], 5);
}

/// Policy is read at the production constructor boundary in fresh processes,
/// so testing both values cannot race another test's environment.
#[test]
fn environment_configures_follow_policy_in_a_fresh_backend() {
    const CHILD: &str = "CT_TEST_REQUEST_FOLLOW_POLICY";
    if let Ok(value) = std::env::var(CHILD) {
        let folder = tempfile::tempdir().expect("recording directory");
        let mut handler = default_handler(folder.path());
        let expected = value == "1";
        assert_eq!(handler.follow_request_spans, expected);
        let empty = page(&mut handler, 0, 1);
        assert_eq!(empty["open"], expected);
        assert_eq!(empty["total"], 0);
    } else {
        for value in ["0", "1"] {
            let output = std::process::Command::new(std::env::current_exe().expect("test binary"))
                .args([
                    "--exact",
                    "environment_configures_follow_policy_in_a_fresh_backend",
                    "--nocapture",
                ])
                .env(CHILD, value)
                .env("CT_FOLLOW_REQUEST_SPANS", value)
                .output()
                .expect("run isolated backend policy check");
            assert!(
                output.status.success(),
                "policy {value}: {}\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            assert!(
                String::from_utf8_lossy(&output.stdout).contains("1 passed"),
                "child must execute its test, not merely exit successfully"
            );
        }
    }
}
