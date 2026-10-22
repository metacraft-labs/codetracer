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

#[test]
fn the_current_position_is_the_last_recorded_event_at_or_before_the_tick() {
    use db_backend::dap_handler::{event_tick_index_of, last_event_at_or_before};
    // Recorded order is not tick order: event 2 was recorded after event 1
    // but happened earlier.
    let events = vec![
        event(0, "a", "m.rs"),
        ProgramEvent {
            direct_location_rr_ticks: 30,
            ..event(1, "b", "m.rs")
        },
        ProgramEvent {
            direct_location_rr_ticks: 20,
            ..event(2, "c", "m.rs")
        },
    ];
    let index = event_tick_index_of(&events);
    assert_eq!(last_event_at_or_before(&index, -1), None);
    assert_eq!(last_event_at_or_before(&index, 0), Some(0));
    assert_eq!(last_event_at_or_before(&index, 25), Some(2));
    assert_eq!(last_event_at_or_before(&index, 30), Some(2));
    assert_eq!(last_event_at_or_before(&index, 1000), Some(2));
}

#[test]
fn the_index_at_tick_answer_matches_the_scan_it_replaced() {
    let mut handler = handler_with_events(hundred_events());
    let body = load(&mut handler, serde_json::json!({ "indexOnly": true, "atRRTicks": 42 }));
    assert_eq!(body["indexAtTick"], 42);
    assert_eq!(body["total"], 100);
}

/// Ten events; the even ones are correlation markers whose key is
/// `order-<i>` and whose content never mentions it, so a match on the key
/// can only come from the marker's own fields.
fn marker_events() -> Vec<ProgramEvent> {
    use db_backend::correlation_markers::{MarkerDirection, MarkerPayload};
    (0..10)
        .map(|i| {
            let mut e = event(i, &format!("write {i}"), "src/main.rs");
            if i % 2 == 0 {
                e.metadata = MarkerPayload {
                    marker_id: i,
                    boundary_id: "order-processing".to_string(),
                    direction: MarkerDirection::Send,
                    key_text: "msg.id".to_string(),
                    key_value: format!("order-{i}"),
                    show_text: None,
                    show_value: None,
                    description: None,
                    format: Some("text".to_string()),
                }
                .encode();
            }
            e
        })
        .collect()
}

#[test]
fn a_search_matches_a_markers_boundary_key_and_shown_value() {
    // The Event Log's filter bar has ONE free-text filter, applied by the
    // engine. A marker is found by what the pane shows for it — its
    // boundary, key and shown value — not only by its event's content.
    let mut handler = handler_with_events(marker_events());
    let body = load(
        &mut handler,
        serde_json::json!({ "start": 0, "count": 10, "search": "ORDER-4" }),
    );
    assert_eq!(contents(&body), vec!["write 4"]);
    assert_eq!(body["total"], 1);
    let by_boundary = load(
        &mut handler,
        serde_json::json!({ "start": 0, "count": 10, "search": "order-processing" }),
    );
    assert_eq!(by_boundary["total"], 5);
}

#[test]
fn a_searched_or_sorted_windows_markers_are_those_of_its_events() {
    // The window of a search or a sort is not a contiguous run of recorded
    // events, so its markers cannot be cut by recorded index: each one must
    // be the marker of an event in the window, numbered by its row in it.
    let mut handler = handler_with_events(marker_events());
    let body = load(
        &mut handler,
        serde_json::json!({ "start": 1, "count": 2, "search": "order" }),
    );
    // Matches are events 0, 2, 4, 6, 8; the window is rows 1..3: 2 and 4.
    assert_eq!(contents(&body), vec!["write 2", "write 4"]);
    let markers = body["markers"].as_array().expect("markers");
    let keys: Vec<(u64, &str)> = markers
        .iter()
        .map(|m| (m["eventIndex"].as_u64().unwrap(), m["keyValue"].as_str().unwrap()))
        .collect();
    assert_eq!(keys, vec![(0, "order-2"), (1, "order-4")]);

    let sorted = load(
        &mut handler,
        serde_json::json!({ "start": 0, "count": 3, "sortKey": "tick", "sortAscending": false }),
    );
    // Descending by tick: events 9, 8, 7 — one marker, event 8, on row 1.
    assert_eq!(contents(&sorted), vec!["write 9", "write 8", "write 7"]);
    let sorted_keys: Vec<(u64, &str)> = sorted["markers"]
        .as_array()
        .expect("markers")
        .iter()
        .map(|m| (m["eventIndex"].as_u64().unwrap(), m["keyValue"].as_str().unwrap()))
        .collect();
    assert_eq!(sorted_keys, vec![(1, "order-8")]);
}
