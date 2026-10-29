//! `ct/seek-to-geid` on a MATERIALIZED trace goes to the step it names.
//!
//! A request span's `startGeid` is the span's `start_step`
//! (`request_spans.rs`), and the Requests pane on every front-end goes to a
//! request's handler by sending it to `ct/seek-to-geid`. A materialized
//! trace's replay serves no geid positions, and the handler used to refuse
//! the request outright ("restore-at is only available for live replay
//! sessions"), so going to a handler moved nothing on any completed
//! recording. For a materialized trace the coordinate is a step id — the
//! position `ct/goto-ticks` moves to — and the handler now goes there.
//!
//! Real: the committed CTFS container (the GDScript fixture), opened through
//! the production reader, and the production `Handler` the server builds for
//! a `.ct` launch. No mocks.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::mpsc;

use codetracer_trace_types::StepId;
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::dap::{DapMessage, ProtocolMessage, Request};
use db_backend::dap_handler::{Handler, SeekToGeidArguments};
use db_backend::recreator_session::RecreatorArgs;
use db_backend::task::TraceKind;
use db_backend::trace_reader::TraceReader;
use serde_json::Value as JsonValue;

fn fixture_ct() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("gdscript")
        .join("gf_values")
        .join("gdscript_trace.ct")
}

fn build_handler(ct: &Path) -> Handler {
    assert!(
        ct.is_file(),
        "fixture trace missing at {} — no silent skip",
        ct.display()
    );
    let reader: Arc<dyn TraceReader> =
        Arc::new(CTFSTraceReader::open(ct).unwrap_or_else(|e| panic!("CTFS open failed for {}: {e}", ct.display())));
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.set_trace_folder(ct);
    handler.load_source_views(ct);
    handler.load_bundled_sources(ct);
    handler.initialized = true;
    handler
}

fn seek(handler: &mut Handler, geid: u64) -> (Option<JsonValue>, Option<JsonValue>) {
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let args = SeekToGeidArguments { geid };
    let req = Request {
        base: ProtocolMessage {
            seq: 1,
            type_: "request".to_string(),
        },
        command: "ct/seek-to-geid".to_string(),
        arguments: serde_json::json!({ "geid": geid }),
    };
    handler
        .seek_to_geid(req, args, tx)
        .expect("ct/seek-to-geid must succeed on a materialized trace");
    let mut moved = None;
    let mut response = None;
    while let Ok(msg) = rx.try_recv() {
        match msg {
            DapMessage::Event(event) if event.event == "ct/complete-move" => moved = Some(event.body),
            DapMessage::Response(r) => response = Some(serde_json::to_value(&r).unwrap()),
            _ => {}
        }
    }
    (moved, response)
}

#[test]
fn seek_to_geid_goes_to_the_named_step_of_a_materialized_trace() {
    let ct = fixture_ct();
    let mut handler = build_handler(&ct);
    for step in [5_u64, 2, 7] {
        let (moved, response) = seek(&mut handler, step);
        assert_eq!(
            handler.step_id,
            StepId(step as i64),
            "seek-to-geid {step} must land on step {step}"
        );
        assert!(
            moved.is_some(),
            "the move is announced (ct/complete-move) for step {step}"
        );
        let response = response.expect("the request is answered");
        assert_eq!(
            response.get("success").and_then(JsonValue::as_bool),
            Some(true),
            "answered as a success: {response:?}"
        );
    }
}
