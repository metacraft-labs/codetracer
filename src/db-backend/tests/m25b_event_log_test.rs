//! M25b — Event Log integration for correlation markers (Layer 1 DAP
//! verification tests).
//!
//! Spec:
//! `codetracer-specs/GUI/Debugging-Features/Correlation-Markers.md` §5.
//! Milestone catalogue: M25b in
//! `codetracer-specs/Planned-Features/Value-Origin-Tracking.milestones.org`.
//!
//! The Layer-1 contract is that the **db-backend** exposes the marker
//! information the Event Log needs through:
//!
//! 1. `ct/event-load` — returns marker rows alongside ordinary events,
//!    carrying the spec-§5.1 metadata (`boundary_id`, `direction`,
//!    `key_value`, `show_value`, `format`, source location).
//! 2. `ct/pairIndexLookup` — `{ boundary_id, direction, key_value }`
//!    request returning the cached counterparts per spec §5.3.
//! 3. The `ct/event-load` response is served from the cache after the
//!    first call — the dedicated `marker_decode_calls` counter pins
//!    the §3.2.1 one-time-evaluation contract at the DAP layer.
//!
//! These three tests mirror the Layer-1 list in the M25b milestone
//! catalogue and run against a fully real `Handler` driven through
//! the production `ct/event-load` / `ct/pairIndexLookup` dispatchers.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::sync::Arc;
use std::sync::mpsc;

use codetracer_trace_types::EventLogKind;
use db_backend::correlation_markers::{MarkerDirection, MarkerPayload};
use db_backend::dap::{DapMessage, ProtocolMessage, Request};
use db_backend::dap_handler::{Handler, PairIndexLookupArguments};
use db_backend::db::Db;
use db_backend::event_db::{SourceLocationFiring, TracepointSourceLocation};
use db_backend::in_memory_trace_reader::InMemoryTraceReader;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::task::{ProgramEvent, TraceKind};
use serde_json::Value as JsonValue;

// ---------------------------------------------------------------------------
// Fixture helpers.
// ---------------------------------------------------------------------------

/// Build an empty in-memory `Db` good enough for the Event-Log DAP
/// surface. The Event Log surface walks `cached_events` (populated by
/// `ensure_events_loaded` via `replay.load_events()`) — for the M25b
/// tests we override `cached_events` directly via the public field so
/// the test fixture stays a single function.
fn make_handler() -> Handler {
    let tmp = tempfile::tempdir().expect("tempdir");
    let workdir = tmp.path().to_path_buf();
    let db = Db::new(&workdir);
    let reader: Arc<dyn db_backend::trace_reader::TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false)
}

/// Synthesise a marker `ProgramEvent` whose metadata is the
/// `MarkerPayload` JSON encoding — the exact wire shape the M25
/// tracepoint integrator emits for hidden marker firings.
fn marker_event(event_index: usize, path: &str, line: i64, step_id: i64, payload: MarkerPayload) -> ProgramEvent {
    ProgramEvent {
        kind: EventLogKind::TraceLogEvent,
        content: format!("marker {} {}", payload.boundary_id, payload.key_value),
        rr_event_id: event_index,
        high_level_path: path.to_string(),
        high_level_line: line,
        metadata: payload.encode(),
        direct_location_rr_ticks: step_id,
        tracepoint_result_index: 0,
        event_index,
        ..ProgramEvent::default()
    }
}

fn payload(
    boundary: &str,
    direction: MarkerDirection,
    key: &str,
    show: Option<&str>,
    marker_id: usize,
) -> MarkerPayload {
    MarkerPayload {
        marker_id,
        boundary_id: boundary.to_string(),
        direction,
        key_text: "msg.id".to_string(),
        key_value: key.to_string(),
        show_text: show.map(|_| "msg.body".to_string()),
        show_value: show.map(String::from),
        description: None,
        format: Some("text".to_string()),
    }
}

/// Pre-populate the handler's `cached_events` slice + the source-
/// location firing index so `ct/event-load` and the per-handler
/// `build_local_pair_index()` both find the marker firings without
/// needing a live `replay.load_events()` pipeline. We deliberately
/// drive both indices in lockstep — the marker rows that the Event
/// Log surface returns *and* the pair-index counterparts must both
/// see the same data.
fn install_marker_events(handler: &mut Handler, events: Vec<ProgramEvent>) {
    // Push events into the in-memory event_db so the source-location
    // index ties firings back to their `ProgramEvent`.
    handler.event_db.single_tables.clear();
    handler.event_db.single_tables.push(db_backend::event_db::SingleTable {
        kind: db_backend::task::DbEventKind::Trace,
        events: events.clone(),
    });
    handler.event_db.firings_by_source_location.clear();
    for (idx, event) in events.iter().enumerate() {
        let location = TracepointSourceLocation::new(event.high_level_path.clone(), event.high_level_line);
        handler
            .event_db
            .firings_by_source_location
            .entry(location)
            .or_default()
            .push(SourceLocationFiring {
                single_table_id: db_backend::event_db::SingleTableId(0),
                index_in_table: db_backend::event_db::IndexInSingleTable(idx),
                step_id: codetracer_trace_types::StepId(event.direct_location_rr_ticks),
            });
    }
    // `event_load` walks `cached_events` rather than the event_db
    // tables — the cache is the §3.2.1 cache contract substrate.
    handler.cached_events_for_tests_set(events);
}

// Test helper trait extension. `cached_events` is module-private; we
// reach into it via a tiny public-for-tests helper added on the
// Handler. Mirrors the `install_materialized_origin_metadata_decoder`
// pattern M21 uses for the metadata decoder.
trait CachedEventsForTests {
    fn cached_events_for_tests_set(&mut self, events: Vec<ProgramEvent>);
}

impl CachedEventsForTests for Handler {
    fn cached_events_for_tests_set(&mut self, events: Vec<ProgramEvent>) {
        // Use the public setter we add to `Handler` for tests.
        self.set_cached_events_for_tests(events);
    }
}

fn make_request(seq: i64, command: &str, args: JsonValue) -> Request {
    Request {
        base: ProtocolMessage {
            seq,
            type_: "request".to_string(),
        },
        command: command.to_string(),
        arguments: args,
    }
}

fn take_response_body(rx: &mpsc::Receiver<DapMessage>, command: &str) -> JsonValue {
    while let Ok(msg) = rx.try_recv() {
        if let DapMessage::Response(resp) = msg
            && resp.command == command
        {
            assert!(
                resp.success,
                "expected `{}` response to succeed, got message={:?} body={:?}",
                command, resp.message, resp.body
            );
            return resp.body;
        }
    }
    panic!("no response on the channel for command `{}`", command);
}

// ---------------------------------------------------------------------------
// Layer 1 / Test 1 — `ct/event-load` returns marker rows with metadata.
// ---------------------------------------------------------------------------

#[test]
fn test_dap_event_log_returns_marker_rows_with_metadata() {
    // Spec §5.1 — A two-marker fixture (one Send, one Recv on the
    // same boundary + key). The response carries the per-row marker
    // metadata fields the Event Log renderer reads.
    let mut handler = make_handler();

    let events = vec![
        marker_event(
            0,
            "src/sender.py",
            7,
            10,
            payload("order-processing", MarkerDirection::Send, "K1", Some("outbound"), 0),
        ),
        marker_event(
            1,
            "src/receiver.py",
            12,
            22,
            payload("order-processing", MarkerDirection::Recv, "K1", Some("inbound"), 1),
        ),
    ];
    install_marker_events(&mut handler, events);

    let (tx, rx) = mpsc::channel::<DapMessage>();
    let req = make_request(1, "ct/event-load", serde_json::json!({ "start": 0, "count": 50 }));
    handler.event_load(req, tx).expect("event_load");

    let body = take_response_body(&rx, "ct/event-load");
    let markers = body
        .get("markers")
        .and_then(JsonValue::as_array)
        .expect("markers array on response");

    assert_eq!(markers.len(), 2, "expected two marker rows, got {markers:?}");

    let send_row = &markers[0];
    assert_eq!(send_row["boundaryId"], "order-processing");
    assert_eq!(send_row["direction"], "send");
    assert_eq!(send_row["keyValue"], "K1");
    assert_eq!(send_row["showValue"], "outbound");
    assert_eq!(send_row["format"], "text");
    assert_eq!(send_row["sourcePath"], "src/sender.py");
    assert_eq!(send_row["sourceLine"], 7);
    assert_eq!(send_row["stepId"], 10);

    let recv_row = &markers[1];
    assert_eq!(recv_row["boundaryId"], "order-processing");
    assert_eq!(recv_row["direction"], "recv");
    assert_eq!(recv_row["showValue"], "inbound");
    assert_eq!(recv_row["sourcePath"], "src/receiver.py");
    assert_eq!(recv_row["sourceLine"], 12);
    assert_eq!(recv_row["stepId"], 22);

    // Sanity: the response also carries the plain `events` array so
    // the Event Log can render ordinary tracepoint rows alongside the
    // marker rows.
    let events_array = body
        .get("events")
        .and_then(JsonValue::as_array)
        .expect("events array on response");
    assert_eq!(events_array.len(), 2);
}

// ---------------------------------------------------------------------------
// Layer 1 / Test 2 — `ct/pairIndexLookup` returns counterparts.
// ---------------------------------------------------------------------------

#[test]
fn test_dap_pair_index_lookup_returns_counterparts_for_send_marker() {
    let mut handler = make_handler();

    // Single-match fixture.
    let events = vec![
        marker_event(
            0,
            "src/sender.py",
            7,
            10,
            payload("order-processing", MarkerDirection::Send, "K-single", Some("S1"), 0),
        ),
        marker_event(
            1,
            "src/receiver.py",
            12,
            22,
            payload("order-processing", MarkerDirection::Recv, "K-single", Some("R1"), 1),
        ),
        // Multi-match fixture: one Send pairs with two Recvs.
        marker_event(
            2,
            "src/sender.py",
            7,
            30,
            payload("envelope-flow", MarkerDirection::Send, "K-multi", Some("S2"), 2),
        ),
        marker_event(
            3,
            "src/r1.py",
            5,
            40,
            payload("envelope-flow", MarkerDirection::Recv, "K-multi", Some("R2-A"), 3),
        ),
        marker_event(
            4,
            "src/r2.py",
            8,
            50,
            payload("envelope-flow", MarkerDirection::Recv, "K-multi", Some("R2-B"), 4),
        ),
    ];
    install_marker_events(&mut handler, events);

    // Case 1 — single match.
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let req = make_request(
        1,
        "ct/pairIndexLookup",
        serde_json::json!({
            "boundaryId": "order-processing",
            "direction": "send",
            "keyValue": "K-single",
        }),
    );
    let args: PairIndexLookupArguments = req.load_args().expect("load PairIndexLookupArguments");
    handler.pair_index_lookup(req, args, tx).expect("pair_index_lookup");
    let body = take_response_body(&rx, "ct/pairIndexLookup");
    let counterparts = body
        .get("counterparts")
        .and_then(JsonValue::as_array)
        .expect("counterparts array");
    assert_eq!(
        counterparts.len(),
        1,
        "single-match case must return exactly one counterpart"
    );
    assert_eq!(counterparts[0]["direction"], "recv");
    assert_eq!(counterparts[0]["keyValue"], "K-single");
    assert_eq!(counterparts[0]["stepId"], 22);

    // Case 2 — multi-match.
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let req = make_request(
        2,
        "ct/pairIndexLookup",
        serde_json::json!({
            "boundaryId": "envelope-flow",
            "direction": "send",
            "keyValue": "K-multi",
        }),
    );
    let args: PairIndexLookupArguments = req.load_args().expect("load PairIndexLookupArguments");
    handler
        .pair_index_lookup(req, args, tx)
        .expect("pair_index_lookup multi");
    let body = take_response_body(&rx, "ct/pairIndexLookup");
    let counterparts = body
        .get("counterparts")
        .and_then(JsonValue::as_array)
        .expect("counterparts array");
    assert_eq!(counterparts.len(), 2, "multi-match case must return two counterparts");
    let step_ids: std::collections::HashSet<i64> = counterparts
        .iter()
        .map(|c| c["stepId"].as_i64().expect("stepId i64"))
        .collect();
    assert!(step_ids.contains(&40));
    assert!(step_ids.contains(&50));

    // Case 3 — zero-match (boundary exists, key doesn't pair).
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let req = make_request(
        3,
        "ct/pairIndexLookup",
        serde_json::json!({
            "boundaryId": "order-processing",
            "direction": "send",
            "keyValue": "no-match",
        }),
    );
    let args: PairIndexLookupArguments = req.load_args().expect("load PairIndexLookupArguments");
    handler
        .pair_index_lookup(req, args, tx)
        .expect("pair_index_lookup zero");
    let body = take_response_body(&rx, "ct/pairIndexLookup");
    let counterparts = body
        .get("counterparts")
        .and_then(JsonValue::as_array)
        .expect("counterparts array");
    assert!(
        counterparts.is_empty(),
        "zero-match case must return empty counterparts"
    );
}

// ---------------------------------------------------------------------------
// Layer 1 / Test 3 — `ct/event-load` marker rows served from cache.
// ---------------------------------------------------------------------------

#[test]
fn test_dap_event_log_marker_response_serves_from_cache_post_load() {
    let mut handler = make_handler();

    let events = vec![
        marker_event(
            0,
            "src/a.py",
            10,
            5,
            payload("b1", MarkerDirection::Send, "K", Some("v1"), 0),
        ),
        marker_event(
            1,
            "src/b.py",
            20,
            8,
            payload("b1", MarkerDirection::Recv, "K", Some("v2"), 1),
        ),
        marker_event(
            2,
            "src/c.py",
            30,
            12,
            payload("b2", MarkerDirection::Send, "K2", None, 2),
        ),
    ];
    install_marker_events(&mut handler, events);

    // First call — populates the marker-row cache, advances the
    // decode-call counter by the number of events.
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let req = make_request(1, "ct/event-load", serde_json::json!({ "start": 0, "count": 50 }));
    handler.event_load(req, tx).expect("event_load first");
    let body_first = take_response_body(&rx, "ct/event-load");
    let first_markers = body_first
        .get("markers")
        .and_then(JsonValue::as_array)
        .expect("markers on first response")
        .clone();

    let decode_calls_after_first = handler.marker_decode_calls.load(std::sync::atomic::Ordering::Relaxed);
    assert!(
        decode_calls_after_first > 0,
        "expected the decoder to fire on first event_load, got {decode_calls_after_first}"
    );

    // Second + Third calls — must serve from cache without re-decoding.
    for seq in 2..=10 {
        let (tx, rx) = mpsc::channel::<DapMessage>();
        let req = make_request(seq, "ct/event-load", serde_json::json!({ "start": 0, "count": 50 }));
        handler.event_load(req, tx).expect("event_load repeat");
        let body = take_response_body(&rx, "ct/event-load");
        let markers = body
            .get("markers")
            .and_then(JsonValue::as_array)
            .expect("markers on repeat response");

        // Byte-equality is a stricter assertion than spec wording —
        // identical JSON values prove the cache served the same
        // projection.
        assert_eq!(
            markers, &first_markers,
            "repeat response must match first byte-for-byte"
        );

        let decode_calls_now = handler.marker_decode_calls.load(std::sync::atomic::Ordering::Relaxed);
        assert_eq!(
            decode_calls_now, decode_calls_after_first,
            "marker decoder must NOT fire on repeat event_load calls"
        );
    }
}
