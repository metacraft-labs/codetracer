//! `ct/event-load` serves a WINDOW of the event log, of a search, and says
//! how large the whole list is.
//!
//! The windowed ViewModels ask for `start`/`count` from the pane's measured
//! viewport and read the list's size from `total`
//! (Viewport-Driven-Loading V2). These tests pin the three facts that
//! depends on: the window is the requested slice, `total` is the size of the
//! whole (searched) list rather than of the window, and `search` narrows the
//! list the window is cut from.
//!
//! The handler is built over an in-memory trace reader and its event cache
//! is set directly: the property is the request handling, which needs no
//! recorded program, and the cache is exactly what `event_load` reads.

use std::sync::{Arc, mpsc};

use codetracer_trace_types::EventLogKind;
use db_backend::dap::{DapMessage, ProtocolMessage, Request};
use db_backend::dap_handler::Handler;
use db_backend::db::Db;
use db_backend::in_memory_trace_reader::InMemoryTraceReader;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::task::{ProgramEvent, TraceKind};
use serde_json::Value as JsonValue;

fn handler_with_events(events: Vec<ProgramEvent>) -> Handler {
    let tmp = tempfile::tempdir().expect("tempdir");
    let db = Db::new(&tmp.path().to_path_buf());
    let reader: Arc<dyn db_backend::trace_reader::TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.set_cached_events_for_tests(events);
    handler
}

fn event(index: usize, content: &str, path: &str) -> ProgramEvent {
    ProgramEvent {
        kind: EventLogKind::Write,
        content: content.to_string(),
        rr_event_id: index,
        high_level_path: path.to_string(),
        high_level_line: 1,
        direct_location_rr_ticks: index as i64,
        event_index: index,
        ..ProgramEvent::default()
    }
}

fn hundred_events() -> Vec<ProgramEvent> {
    (0..100)
        .map(|i| {
            let content = if i % 10 == 0 {
                format!("Tick {i}")
            } else {
                format!("line {i}")
            };
            let path = if i == 55 { "src/ticker.rs" } else { "src/main.rs" };
            event(i, &content, path)
        })
        .collect()
}

fn load(handler: &mut Handler, args: JsonValue) -> JsonValue {
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let req = Request {
        base: ProtocolMessage {
            seq: 1,
            type_: "request".to_string(),
        },
        command: "ct/event-load".to_string(),
        arguments: args,
    };
    handler.event_load(req, tx).expect("event_load");
    while let Ok(msg) = rx.try_recv() {
        if let DapMessage::Response(resp) = msg
            && resp.command == "ct/event-load"
        {
            assert!(resp.success, "ct/event-load failed: {:?}", resp.message);
            return resp.body;
        }
    }
    panic!("no ct/event-load response");
}

fn contents(body: &JsonValue) -> Vec<String> {
    body["events"]
        .as_array()
        .expect("events")
        .iter()
        .map(|e| e["content"].as_str().unwrap_or("").to_string())
        .collect()
}

#[test]
fn the_window_is_the_requested_slice_and_total_is_the_whole_log() {
    let mut handler = handler_with_events(hundred_events());
    let body = load(&mut handler, serde_json::json!({ "start": 40, "count": 5 }));
    assert_eq!(
        contents(&body),
        vec!["Tick 40", "line 41", "line 42", "line 43", "line 44"]
    );
    assert_eq!(body["total"], 100);
}

#[test]
fn a_search_narrows_the_list_the_window_and_total_are_cut_from() {
    let mut handler = handler_with_events(hundred_events());
    // "tick" matches the ten `Tick n` contents (case-insensitively) and the
    // one event in `src/ticker.rs`: eleven events.
    let body = load(
        &mut handler,
        serde_json::json!({ "start": 0, "count": 50, "search": "tick" }),
    );
    assert_eq!(body["total"], 11);
    let found = contents(&body);
    assert_eq!(found.len(), 11);
    assert!(found.contains(&"line 55".to_string()), "path match missing: {found:?}");

    let page = load(
        &mut handler,
        serde_json::json!({ "start": 2, "count": 2, "search": "tick" }),
    );
    assert_eq!(contents(&page), vec!["Tick 20", "Tick 30"]);
    assert_eq!(page["total"], 11);
}

#[test]
fn an_empty_search_is_no_search() {
    let mut handler = handler_with_events(hundred_events());
    let body = load(
        &mut handler,
        serde_json::json!({ "start": 0, "count": 3, "search": "" }),
    );
    assert_eq!(body["total"], 100);
    assert_eq!(contents(&body).len(), 3);
}
