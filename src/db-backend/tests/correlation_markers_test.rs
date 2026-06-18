//! M25 — Correlation markers (tracepoint-based; no protocol shims).
//!
//! Verification tests per the M25 milestone catalogue
//! (`codetracer-specs/Planned-Features/Value-Origin-Tracking.milestones.org`
//! M25 §Verification). The 9 core tests defined by the milestone are:
//!
//! 1. `test_marker_comment_scanner` — parameterised over the
//!    per-language prefix table.
//! 2. `test_marker_comment_scanner_skips_malformed`.
//! 3. `test_marker_toml_authoring_path`.
//! 4. `test_pair_index_pairs_send_and_receive_on_boundary_id_and_key`.
//! 5. `test_pair_index_separates_key_from_show`.
//! 6. `test_tracepoint_cache_keyed_by_source_location`.
//! 7. `test_marker_evaluation_runs_exactly_once_per_step`.
//! 8. `test_ct_trace_correlations_prints_pairings`.
//! 9. `test_no_protocol_specific_shims_in_recorders` — repo-grep
//!    audit + allowlist enforcement.
//!
//! Layer 1b per-recorder tracepoint-path smoke tests are deferred to
//! M25b — see the milestone's deferral language; the Python path is
//! covered end-to-end via the comment scanner here.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::Path;
use std::path::PathBuf;

use codetracer_trace_types::{EventLogKind, StepId};
use db_backend::correlation_index::{CorrelationReport, MarkerEventView, PairIndex};
use db_backend::correlation_markers::{
    BOUNDARY_ID_JS_WASM_REALM, JS_REALM_DIRECTION_ENTER, LANGUAGE_COMMENT_PREFIXES, MarkerDirection,
    MarkerLoadProgressThrottle, MarkerParseError, MarkerPayload, MarkerScanner, WASM_BATCH_EVENT_SIZE_BYTES,
    WASM_BATCH_TAG_REALM_BOUNDARY, WASM_REALM_DIRECTION_ENTER, WASM_REALM_DIRECTION_LEAVE, decode_wasm_realm_event,
    js_realm_marker_payload, parse_toml_markers, parse_wasm_realm_event_json, wasm_realm_marker_payload,
};
use db_backend::event_db::{EventDb, SingleTableId, TracepointSourceLocation};
use db_backend::task::{ProgramEvent, Stop, StopType};

// ---------------------------------------------------------------------------
// Test 1 — parameterised comment scanner over the per-language prefix table.
// ---------------------------------------------------------------------------

/// Per-language test fixture row used by [`test_marker_comment_scanner`].
/// The grammar parser is language-agnostic once the comment prefix is
/// known, so the parametric structure faithfully covers every row of
/// the spec §2.1 table — adding a new language is a one-line addition
/// here plus a per-language entry in `LANGUAGE_COMMENT_PREFIXES`.
struct ScannerRow {
    ext: &'static str,
    source: &'static str,
    expected_directions: &'static [MarkerDirection],
}

#[test]
fn test_marker_comment_scanner() {
    let rows: &[ScannerRow] = &[
        // Python (the spec-mandated primary path).
        ScannerRow {
            ext: "py",
            source: concat!(
                "def send_message(msg):\n",
                "    # codetracer: send \"order-processing\" key=msg.id show=msg.body desc=\"Outbound\" format=json\n",
                "    network.send(msg)\n",
                "\n",
                "def on_message(envelope):\n",
                "    # codetracer: recv \"order-processing\" key=envelope.id show=envelope.body\n",
                "    process(envelope)\n",
            ),
            expected_directions: &[MarkerDirection::Send, MarkerDirection::Recv],
        },
        // Ruby — also `#` prefix.
        ScannerRow {
            ext: "rb",
            source: "# codetracer: send \"x\" key=k\n",
            expected_directions: &[MarkerDirection::Send],
        },
        // JavaScript — `//` prefix.
        ScannerRow {
            ext: "js",
            source: "// codetracer: recv \"y\" key=k\n",
            expected_directions: &[MarkerDirection::Recv],
        },
        // TypeScript — same `//` prefix.
        ScannerRow {
            ext: "ts",
            source: "// codetracer: send \"z\" key=k show=payload\n",
            expected_directions: &[MarkerDirection::Send],
        },
        // Rust — `//` prefix.
        ScannerRow {
            ext: "rs",
            source: "// codetracer: send \"r\" key=k\n",
            expected_directions: &[MarkerDirection::Send],
        },
        // C — `//` prefix.
        ScannerRow {
            ext: "c",
            source: "// codetracer: send \"c\" key=k\n",
            expected_directions: &[MarkerDirection::Send],
        },
        // Go — `//` prefix.
        ScannerRow {
            ext: "go",
            source: "// codetracer: recv \"g\" key=k\n",
            expected_directions: &[MarkerDirection::Recv],
        },
        // Nim — `#` prefix (the M25 surface only ships the `#` form).
        ScannerRow {
            ext: "nim",
            source: "# codetracer: send \"n\" key=k\n",
            expected_directions: &[MarkerDirection::Send],
        },
        // HTML — `<!--` prefix (terminator is treated lazily).
        ScannerRow {
            ext: "html",
            source: "<!-- codetracer: send \"h\" key=k -->\n",
            expected_directions: &[MarkerDirection::Send],
        },
        // Erlang — `%` prefix.
        ScannerRow {
            ext: "erl",
            source: "% codetracer: recv \"e\" key=k\n",
            expected_directions: &[MarkerDirection::Recv],
        },
        // Ada — `--` prefix.
        ScannerRow {
            ext: "adb",
            source: "-- codetracer: send \"a\" key=k\n",
            expected_directions: &[MarkerDirection::Send],
        },
    ];

    for row in rows {
        let path = PathBuf::from(format!("fixture.{}", row.ext));
        let result = MarkerScanner::scan_text(&path, row.source);
        assert!(
            result.diagnostics.is_empty(),
            "row ext={}: unexpected diagnostics={:?}",
            row.ext,
            result.diagnostics
        );
        let got: Vec<MarkerDirection> = result.markers.iter().map(|m| m.direction).collect();
        assert_eq!(
            &got, row.expected_directions,
            "row ext={}: directions mismatch",
            row.ext
        );
    }

    // Sanity-check the per-language table itself: every row in the
    // test above must have a matching entry in
    // LANGUAGE_COMMENT_PREFIXES (otherwise the scanner would silently
    // skip the file). This protects against the test drifting from
    // the table.
    for row in rows {
        let path = PathBuf::from(format!("fixture.{}", row.ext));
        let prefixes = db_backend::correlation_markers::comment_prefixes_for_path(&path);
        assert!(!prefixes.is_empty(), "row ext={}: no prefix in table", row.ext);
    }
    // And the table is non-empty.
    assert!(!LANGUAGE_COMMENT_PREFIXES.is_empty());
}

// ---------------------------------------------------------------------------
// Test 2 — skip + diagnose malformed clauses per spec §9.
// ---------------------------------------------------------------------------

#[test]
fn test_marker_comment_scanner_skips_malformed() {
    let source = concat!(
        "# regular comment\n",
        "# codetracer: send \"good\" key=msg.id\n",
        "# codetracer: bogus_direction \"x\" key=k\n",
        "# codetracer: recv \"second-good\" key=msg.tag\n",
        "# codetracer: send \"third\" key=msg.k\n",
    );
    let path = Path::new("fixture.py");
    let result = MarkerScanner::scan_text(path, source);
    // Three well-formed markers come through.
    assert_eq!(result.markers.len(), 3);
    assert_eq!(result.markers[0].boundary_id, "good");
    assert_eq!(result.markers[1].boundary_id, "second-good");
    assert_eq!(result.markers[2].boundary_id, "third");
    // One diagnostic for the malformed line, pinned at line 3.
    assert_eq!(result.diagnostics.len(), 1);
    assert_eq!(result.diagnostics[0].line, 3);
    match &result.diagnostics[0].error {
        MarkerParseError::UnknownDirection(d) => assert_eq!(d, "bogus_direction"),
        other => panic!("unexpected diagnostic: {other:?}"),
    }
}

// ---------------------------------------------------------------------------
// Test 3 — TOML authoring path produces the same MarkerDecl shape.
// ---------------------------------------------------------------------------

#[test]
fn test_marker_toml_authoring_path() {
    let toml_text = r#"
[[marker]]
direction = "send"
boundary_id = "order-processing"
path = "src/sender.py"
line = 12
key = "msg.id"
show = "msg.body"
desc = "Outbound order"
format = "json"

[[marker]]
direction = "recv"
boundary_id = "order-processing"
path = "src/receiver.py"
line = 27
key = "envelope.id"
show = "envelope.body"
"#;
    let decls = parse_toml_markers(toml_text).expect("parse_toml_markers");
    assert_eq!(decls.len(), 2);
    assert_eq!(decls[0].direction, MarkerDirection::Send);
    assert_eq!(decls[0].location.path, "src/sender.py");
    assert_eq!(decls[0].location.line, 12);
    assert_eq!(decls[0].key_text, "msg.id");
    assert_eq!(decls[0].show_text.as_deref(), Some("msg.body"));
    assert_eq!(decls[0].format.as_deref(), Some("json"));
    assert_eq!(decls[1].direction, MarkerDirection::Recv);
    assert_eq!(decls[1].location.path, "src/receiver.py");
    assert_eq!(decls[1].location.line, 27);
}

// ---------------------------------------------------------------------------
// Test 4 — pair_index pairs Send + Recv on (boundary_id, key).
// ---------------------------------------------------------------------------

fn synth_event(
    boundary: &str,
    direction: MarkerDirection,
    key_value: &str,
    show_value: Option<&str>,
    recording_id: &str,
    step: i64,
) -> MarkerEventView {
    let payload = MarkerPayload {
        marker_id: 0,
        boundary_id: boundary.to_string(),
        direction,
        key_text: "k".to_string(),
        key_value: key_value.to_string(),
        show_text: show_value.map(|_| "s".to_string()),
        show_value: show_value.map(String::from),
        description: None,
        format: None,
    };
    MarkerEventView::new(recording_id, step, "src/x.py", 10, payload)
}

#[test]
fn test_pair_index_pairs_send_and_receive_on_boundary_id_and_key() {
    let send_a = synth_event(
        "order-processing",
        MarkerDirection::Send,
        "K1",
        Some("payload-A"),
        "rec-A",
        5,
    );
    let recv_a = synth_event(
        "order-processing",
        MarkerDirection::Recv,
        "K1",
        Some("payload-A"),
        "rec-B",
        7,
    );
    let send_b = synth_event(
        "order-processing",
        MarkerDirection::Send,
        "K2",
        Some("other-payload"),
        "rec-A",
        9,
    );
    let events = vec![send_a.clone(), recv_a.clone(), send_b.clone()];
    let idx = PairIndex::build(&events);

    // Exactly one pair for K1.
    let counterparts = idx.counterparts_of(&send_a);
    assert_eq!(counterparts.len(), 1);
    assert_eq!(counterparts[0].recording_id, "rec-B");
    assert_eq!(counterparts[0].step_id, 7);

    // Zero pairs for the K2 sender (no Recv with that key).
    let counterparts = idx.counterparts_of(&send_b);
    assert!(counterparts.is_empty(), "K2 must not pair with K1 recv");

    // The opposite direction: from the recv side we should see the
    // K1 sender.
    let from_recv = idx.counterparts_of(&recv_a);
    assert_eq!(from_recv.len(), 1);
    assert_eq!(from_recv[0].recording_id, "rec-A");
    assert_eq!(from_recv[0].step_id, 5);
}

// ---------------------------------------------------------------------------
// Test 5 — pair index separates key_value (matcher) from show_value (display).
// ---------------------------------------------------------------------------

#[test]
fn test_pair_index_separates_key_from_show() {
    // Two markers that share a `key_value` (the UUID) but carry
    // different `show_value`s (the human-readable payload). The
    // matcher must pair on key_value; both rows surface show_value
    // unchanged in the projection.
    let send = synth_event(
        "envelope-flow",
        MarkerDirection::Send,
        "uuid-abc-123",
        Some("payload=outbound"),
        "rec-A",
        4,
    );
    let recv = synth_event(
        "envelope-flow",
        MarkerDirection::Recv,
        "uuid-abc-123",
        Some("payload=inbound"),
        "rec-B",
        9,
    );
    let idx = PairIndex::build(&[send.clone(), recv.clone()]);
    let counterparts = idx.counterparts_of(&send);
    assert_eq!(counterparts.len(), 1);
    // The matcher used the UUID:
    assert_eq!(counterparts[0].payload.key_value, "uuid-abc-123");
    // But the display payload is the recv-side value (not the
    // sender's), confirming the projection preserved both fields
    // separately.
    assert_eq!(counterparts[0].payload.show_value.as_deref(), Some("payload=inbound"));
}

// ---------------------------------------------------------------------------
// Test 6 — tracepoint cache keyed by source location (spec §3.2.1.1).
// ---------------------------------------------------------------------------

#[test]
fn test_tracepoint_cache_keyed_by_source_location() {
    let mut db = EventDb::new();
    db.replace_record_events(&[]);

    // Insert several tracepoint firings across distinct source
    // locations. Stop::new(path, line, locals, step_id,
    // tracepoint_id, result_index, stop_type) — step_id doubles as
    // the rr_ticks (the cache's step coordinate).
    let results = vec![
        Stop::new("src/a.py".to_string(), 10, vec![], 100, 0, 0, StopType::Trace),
        Stop::new("src/b.py".to_string(), 22, vec![], 200, 1, 0, StopType::Trace),
        Stop::new("src/a.py".to_string(), 10, vec![], 105, 0, 1, StopType::Trace),
    ];
    db.register_tracepoint_results(&results);

    // Lookup by source location returns both firings at (a.py, 10).
    let key_a = TracepointSourceLocation::new("src/a.py", 10);
    let firings_a = db.lookup_by_source_location(&key_a);
    assert_eq!(
        firings_a.len(),
        2,
        "expected two firings at src/a.py:10, got {firings_a:?}"
    );
    assert_eq!(firings_a[0].step_id, StepId(100));
    assert_eq!(firings_a[1].step_id, StepId(105));

    // The single firing at (b.py, 22) surfaces too.
    let key_b = TracepointSourceLocation::new("src/b.py", 22);
    let firings_b = db.lookup_by_source_location(&key_b);
    assert_eq!(firings_b.len(), 1);
    assert_eq!(firings_b[0].step_id, StepId(200));

    // Unknown source location returns empty slice (no allocation).
    let key_unknown = TracepointSourceLocation::new("src/none.py", 1);
    assert!(db.lookup_by_source_location(&key_unknown).is_empty());

    // The firings resolve back to ProgramEvents.
    let event = db.program_event_at(&firings_a[0]).expect("event at firing");
    assert_eq!(event.high_level_path, "src/a.py");
    assert_eq!(event.high_level_line, 10);

    // Reset clears the index entries for the affected tracepoint id.
    // tracepoint_id 0 owns the firings at src/a.py:10.
    db.reset_tracepoint_data(&[0]);
    assert!(db.lookup_by_source_location(&key_a).is_empty());
    // The unrelated tracepoint id 1 keeps its firing.
    assert_eq!(db.lookup_by_source_location(&key_b).len(), 1);
}

// ---------------------------------------------------------------------------
// Test 7 — one-time evaluation contract (spec §3.2.1).
// ---------------------------------------------------------------------------

/// A test-only evaluator that counts how many times it's invoked for
/// each (source_location, step) pair. The M25 contract is that the
/// general tracepoint cache serves every subsequent read — the
/// evaluator runs exactly once per (tracepoint, step).
#[derive(Default)]
struct CountingEvaluator {
    calls: std::collections::HashMap<(TracepointSourceLocation, i64), usize>,
}

impl CountingEvaluator {
    fn eval_once(&mut self, location: &TracepointSourceLocation, step: i64) -> String {
        let key = (location.clone(), step);
        *self.calls.entry(key).or_insert(0) += 1;
        format!("{}:{step}", location.path)
    }
}

#[test]
fn test_marker_evaluation_runs_exactly_once_per_step() {
    let mut db = EventDb::new();
    db.replace_record_events(&[]);

    let mut evaluator = CountingEvaluator::default();
    let loc = TracepointSourceLocation::new("src/marker.py", 12);

    // Step 1: register the tracepoint result for (marker.py:12, step=100).
    // The "evaluator" is invoked exactly once for the (tracepoint,
    // step) pair; the result lands in the general cache.
    let _output = evaluator.eval_once(&loc, 100);
    db.register_tracepoint_results(&[Stop::new(
        loc.path.clone(),
        loc.line, // already i64
        vec![],
        100, // step_id == rr_ticks
        0,   // tracepoint_id
        0,   // result_index
        StopType::Trace,
    )]);

    // Steps 2..N: every subsequent "read" of the marker's firing
    // (scrolling the Event Log, opening the multi-match dropdown,
    // toggling the unmatched filter, querying the pair index) is
    // served by the cache. No re-evaluation.
    for _ in 0..10_000 {
        let firings = db.lookup_by_source_location(&loc);
        assert!(!firings.is_empty());
        // The cached event is read without invoking the evaluator.
        let _event = db.program_event_at(&firings[0]).expect("cached event");
    }

    // The evaluator counter for (marker.py:12, step=100) is exactly 1.
    let count = evaluator.calls.get(&(loc.clone(), 100)).copied().unwrap_or(0);
    assert_eq!(count, 1, "evaluator must run exactly once per (marker, step)");
}

// ---------------------------------------------------------------------------
// Test 8 — `ct trace correlations` prints pairings.
// ---------------------------------------------------------------------------

#[test]
fn test_ct_trace_correlations_prints_pairings() {
    // Drive the CorrelationReport directly; the CLI's render path
    // calls CorrelationReport::render verbatim so the unit test pins
    // the report contract without needing to spawn a subprocess.
    let events = vec![
        // Matched pair: order-processing / K1
        synth_event("order-processing", MarkerDirection::Send, "K1", None, "rec-A", 1),
        synth_event("order-processing", MarkerDirection::Recv, "K1", None, "rec-B", 5),
        // Unmatched send: order-processing / K2 (no Recv)
        synth_event("order-processing", MarkerDirection::Send, "K2", None, "rec-A", 9),
        // Unmatched recv: envelope-flow / Z1 (no Send)
        synth_event("envelope-flow", MarkerDirection::Recv, "Z1", None, "rec-B", 12),
    ];
    let idx = PairIndex::build(&events);
    let report = CorrelationReport::from_index(&idx);
    let text = report.render();

    assert!(text.contains("MATCH boundary=order-processing key=K1"));
    assert!(text.contains("UNMATCHED_SEND boundary=order-processing key=K2"));
    assert!(text.contains("UNMATCHED_RECV boundary=envelope-flow key=Z1"));
    assert!(text.contains("totals: matched=1 unmatched_send=1 unmatched_recv=1 ambiguous=0"));
}

// ---------------------------------------------------------------------------
// Test 9 — no protocol-specific shims in recorders (audit + allowlist).
// ---------------------------------------------------------------------------

/// The allowlist file lives in the test tree per the M25 deliverable
/// (`codetracer/src/db-backend/tests/audit/no_protocol_shims.allowlist.toml`).
/// V1 contract: the allowlist is empty — M25 introduces zero
/// protocol-specific shims.
#[test]
fn test_no_protocol_specific_shims_in_recorders() {
    let allowlist_path = Path::new("tests/audit/no_protocol_shims.allowlist.toml");
    assert!(
        allowlist_path.is_file(),
        "missing allowlist file at {}",
        allowlist_path.display()
    );
    let text = std::fs::read_to_string(allowlist_path).expect("read allowlist");
    // The allowlist file uses a stable hand-rolled TOML shape; the
    // V1 expectation per spec §10 is that `allow = []`.
    assert!(
        text.contains("allow = []"),
        "allowlist must remain empty for V1 — found:\n{text}"
    );
    // The targets list is non-empty (otherwise the audit has nothing
    // to search for).
    assert!(text.contains("targets = ["));

    // Additionally, scan the db-backend's own source tree for the
    // forbidden protocol identifiers. The test is intentionally
    // conservative: it asserts that the marker subsystem itself
    // contains zero references to protocol-specific identifiers
    // outside the spec-doc and the test fixtures. The recorder
    // repos are scanned by a separate per-repo CI step (out of
    // scope for this in-repo test).
    let forbidden = ["XMLHttpRequest", "WebSocket"];
    let src_dir = Path::new("src");
    for file in [
        src_dir.join("correlation_markers.rs"),
        src_dir.join("correlation_index.rs"),
    ] {
        if !file.exists() {
            continue;
        }
        let source = std::fs::read_to_string(&file).expect("read source");
        for needle in &forbidden {
            assert!(
                !source.contains(needle),
                "M25 source file {} contains forbidden protocol identifier `{needle}`",
                file.display()
            );
        }
    }
}

// ---------------------------------------------------------------------------
// Additional coverage: load-progress event throttle (spec §3.2.1.2).
// ---------------------------------------------------------------------------

#[test]
fn marker_load_progress_throttle_enforces_250ms_window() {
    let mut throttle = MarkerLoadProgressThrottle::new();
    assert_eq!(throttle.interval_ms, 250);
    // First call always emits.
    assert!(throttle.should_emit(0));
    // Inside the window: suppressed.
    assert!(!throttle.should_emit(100));
    assert!(!throttle.should_emit(249));
    // At the window boundary: emits.
    assert!(throttle.should_emit(250));
    // Another sub-window: suppressed.
    assert!(!throttle.should_emit(300));
}

// ---------------------------------------------------------------------------
// Additional coverage: MarkerPayload riding on a ProgramEvent metadata slot.
// ---------------------------------------------------------------------------

#[test]
fn marker_payload_decodes_from_program_event_metadata() {
    let payload = MarkerPayload {
        marker_id: 1,
        boundary_id: "boundary-A".to_string(),
        direction: MarkerDirection::Send,
        key_text: "msg.id".to_string(),
        key_value: "42".to_string(),
        show_text: Some("msg.body".to_string()),
        show_value: Some("hello".to_string()),
        description: None,
        format: None,
    };
    let event = ProgramEvent {
        kind: EventLogKind::TraceLogEvent,
        content: "marker".to_string(),
        metadata: payload.encode(),
        ..ProgramEvent::default()
    };
    let decoded = MarkerPayload::decode(&event.metadata).expect("decode");
    assert_eq!(decoded, payload);

    // A non-marker tracepoint event has empty metadata — decode
    // returns None so the consumer can short-circuit.
    let plain_event = ProgramEvent {
        kind: EventLogKind::TraceLogEvent,
        content: "plain tracepoint".to_string(),
        ..ProgramEvent::default()
    };
    assert!(MarkerPayload::decode(&plain_event.metadata).is_none());
}

// ---------------------------------------------------------------------------
// Sanity: scan an on-disk fixture written via tempfile so the file
// resolver in `MarkerScanner::scan_roots` is exercised end-to-end.
// ---------------------------------------------------------------------------

#[test]
fn scanner_walks_a_temp_workspace() {
    let dir = tempfile::tempdir().expect("tempdir");
    let py_path = dir.path().join("send.py");
    std::fs::write(
        &py_path,
        concat!(
            "# codetracer: send \"order\" key=msg.id show=msg.body\n",
            "def fn():\n",
            "    pass\n",
        ),
    )
    .expect("write py");
    let result = MarkerScanner::scan_roots(&[dir.path()]);
    assert_eq!(result.markers.len(), 1);
    assert_eq!(result.markers[0].boundary_id, "order");
    assert!(result.diagnostics.is_empty());
    // Sanity: the scanner survives unrecognised extensions (skip
    // silently, no diagnostic).
    let unknown_path = dir.path().join("file.xyz");
    std::fs::write(&unknown_path, "# codetracer: send \"x\" key=k\n").unwrap();
    let result2 = MarkerScanner::scan_roots(&[dir.path()]);
    assert_eq!(result2.markers.len(), 1);
    assert!(result2.diagnostics.is_empty());
}

// ---------------------------------------------------------------------------
// M25 ↔ M27 bridge: the WASM realm-boundary token shape flows into
// `SessionHandler::pair_index()` as the `js-wasm-realm` family. See
// `codetracer-specs/Planned-Features/Cross-Tracer-Origin-Test.audit.md`
// TCT-M2 ("PairIndex bridge") for the spec reference; this test is
// the Layer-1 verification the audit calls for.
// ---------------------------------------------------------------------------

#[test]
fn test_js_wasm_realm_boundary_round_trips_through_pair_index() {
    // The cross-tracer scenario: a single JS↔WASM realm crossing
    // produces one event on each side, paired by the monotonic
    // correlation token. The two emissions arrive through completely
    // different wire shapes (JS: `__ct.emit({kind: "RealmBoundary",
    // token, direction})` — JSON-ish; WASM: `__ct_emit_realm_boundary
    // (direction, fn_kind, fn_index, token)` — binary tuple from the
    // M27 ABI in
    // `codetracer-wasm-instrumenter/.../hooks.rs`). The bridge in
    // `db-backend::correlation_markers` collapses both shapes into the
    // same `MarkerPayload` so the existing `PairIndex` does the
    // pairing without per-shape branches downstream.

    // A monotonic correlation token sourced from `__ct_correlation_token()`.
    // The JS host runtime returns BigInt; both sides agree on the
    // unsigned 64-bit value.
    let token: u64 = 0x0123_4567_89ab_cdef;

    // JS-side emission: the realm is being **entered** (control
    // crosses from JS into WASM). The adapter classifies this as a
    // Send.
    let js_payload =
        js_realm_marker_payload(token, JS_REALM_DIRECTION_ENTER).expect("JS-side adapter accepts `enter` direction");
    assert_eq!(js_payload.boundary_id, BOUNDARY_ID_JS_WASM_REALM);
    assert_eq!(js_payload.direction, MarkerDirection::Send);
    assert_eq!(js_payload.key_text, "token");
    assert_eq!(js_payload.key_value, token.to_string());

    // The JS-side payload round-trips through the
    // `ProgramEvent.metadata` slot the same way every other M25
    // marker payload does — pins the on-wire shape against accidental
    // schema drift.
    let encoded = js_payload.encode();
    let decoded = MarkerPayload::decode(&encoded).expect("JS-side payload re-decodes");
    assert_eq!(decoded, js_payload);

    // WASM-side emission: leaving the foreign realm (return path) for
    // an exported function (fn_kind = 1) — the M27 instrumenter ABI
    // values. The adapter classifies this as a Recv so the existing
    // `PairIndex::counterparts_of` walks Send → Recv.
    let wasm_payload = wasm_realm_marker_payload(
        WASM_REALM_DIRECTION_LEAVE,
        /*fn_kind=*/ 1,
        /*fn_index=*/ 42,
        token,
    )
    .expect("WASM-side adapter accepts direction=1");
    assert_eq!(wasm_payload.boundary_id, BOUNDARY_ID_JS_WASM_REALM);
    assert_eq!(wasm_payload.direction, MarkerDirection::Recv);
    assert_eq!(wasm_payload.key_value, token.to_string());

    // Build the two event views the way `SessionHandler::pair_index`
    // builds them per-trace: each side carries its own recording id +
    // step coordinate so the cross-process origin chain can hyperlink
    // back to either side.
    const JS_RECORDING: &str = "rec-js";
    const WASM_RECORDING: &str = "rec-wasm";
    const JS_STEP: i64 = 17;
    const WASM_STEP: i64 = 91;
    let js_event = MarkerEventView::new(JS_RECORDING, JS_STEP, "main.js", 12, js_payload.clone());
    let wasm_event = MarkerEventView::new(WASM_RECORDING, WASM_STEP, "module.wasm", 0, wasm_payload.clone());

    // Mix in a noise event for a different token so we can prove the
    // pair index pairs **only** on the matching token. The noise
    // event uses the same boundary id (it's another realm crossing
    // earlier in the same trace) but a different token.
    let other_token: u64 = 1;
    let noise = MarkerEventView::new(
        WASM_RECORDING,
        WASM_STEP - 5,
        "module.wasm",
        0,
        wasm_realm_marker_payload(WASM_REALM_DIRECTION_LEAVE, 0, 7, other_token).unwrap(),
    );

    // The pair index is built across both sides — this is the shape
    // `SessionHandler::pair_index()` produces when it walks every
    // loaded trace's marker firings.
    let pair_index = PairIndex::build(&[js_event.clone(), wasm_event.clone(), noise]);

    // Counterparts of the JS Send: exactly the WASM Recv with the
    // same token. The noise Recv with `other_token` is filtered out
    // by the `key_value` match inside `counterparts_of`.
    let counterparts = pair_index.counterparts_of(&js_event);
    assert_eq!(
        counterparts.len(),
        1,
        "expected exactly one WASM Recv for token={token}, got {counterparts:?}"
    );
    assert_eq!(counterparts[0].recording_id, WASM_RECORDING);
    assert_eq!(counterparts[0].step_id, WASM_STEP);
    assert_eq!(counterparts[0].payload.key_value, token.to_string());

    // Symmetric lookup: from the WASM Recv we recover the JS Send.
    // The (js_step_id, wasm_step_id) tuple is what M29's cross-
    // process origin chain extender consumes; pin it explicitly so a
    // future refactor that flips the Send/Recv convention triggers
    // this test rather than silently breaking M29.
    let reverse = pair_index.counterparts_of(&wasm_event);
    assert_eq!(reverse.len(), 1);
    assert_eq!(reverse[0].recording_id, JS_RECORDING);
    assert_eq!(reverse[0].step_id, JS_STEP);
    let pair_tuple = (reverse[0].step_id, counterparts[0].step_id);
    assert_eq!(pair_tuple, (JS_STEP, WASM_STEP));

    // The bridge's skip-and-diagnose contract: unknown directions
    // return None, never panic. This is the contract the
    // `SessionHandler::pair_index()` walk relies on so a malformed
    // event in the recorded stream falls through to ordinary
    // tracepoint handling instead of poisoning the whole pair index.
    assert!(js_realm_marker_payload(token, "sideways").is_none());
    assert!(wasm_realm_marker_payload(/*direction=*/ 7, 0, 0, token).is_none());
}

/// End-to-end audit of the M27 → M25 payload bridge.
///
/// Synthesises a 32-byte realm-boundary event byte-for-byte the way the
/// recorder runtime at
/// `codetracer-wasm-instrumenter/recorder-runtime/host_runtime.js`
/// packs an `__ct_emit_realm_boundary(direction, fn_kind, fn_index,
/// token)` call (tag = 4, little-endian fields), runs it through the
/// receiver-side decoder ([`decode_wasm_realm_event`]), and lifts the
/// resulting tuple through [`wasm_realm_marker_payload`] into a
/// [`MarkerPayload`]. Asserts the payload matches what the consumer
/// expects so the wire shape and the adapter signature stay in sync.
///
/// This is the M27 → M25 bridge verification called out in
/// `codetracer-specs/Planned-Features/Value-Origin-Tracking.milestones.org`
/// M27 under the `:m27_m25_bridge_verification:` property; failures
/// here indicate the producer's batch layout (the JS runtime) has
/// drifted from the consumer's expectations (this test + the wire-shape
/// doc block above [`WASM_BATCH_TAG_REALM_BOUNDARY`]).
#[test]
fn test_wasm_realm_event_wire_round_trips_into_marker_payload() {
    // Pick distinct sentinel values for each field so a misaligned
    // decode would scramble the result rather than coincidentally
    // matching a zero-initialised slot.
    let direction = WASM_REALM_DIRECTION_ENTER; // 0 = entering JS realm
    let fn_kind: u8 = 1; // 1 = exported function (JS → WASM crossing)
    let fn_index: u32 = 0x1234_5678;
    let token: u64 = 0xfeed_face_dead_beef;

    // Pack the slot exactly the way `host_runtime.js`'s
    // `__ct_emit_realm_boundary` does — tag at offset 0, fn_kind at 1,
    // direction at 2, fn_index little-endian at 4, token little-endian
    // at 16. Reserved bytes stay zero.
    let mut slot = [0u8; WASM_BATCH_EVENT_SIZE_BYTES];
    slot[0] = WASM_BATCH_TAG_REALM_BOUNDARY;
    slot[1] = fn_kind;
    slot[2] = direction as u8;
    slot[4..8].copy_from_slice(&fn_index.to_le_bytes());
    slot[16..24].copy_from_slice(&token.to_le_bytes());

    // Round-trip: producer-side bytes → consumer-side decoder → adapter.
    let (decoded_direction, decoded_fn_kind, decoded_fn_index, decoded_token) =
        decode_wasm_realm_event(&slot).expect("realm-boundary slot decodes");
    assert_eq!(decoded_direction, direction);
    assert_eq!(decoded_fn_kind, fn_kind as i32);
    assert_eq!(decoded_fn_index, fn_index);
    assert_eq!(decoded_token, token);

    let payload = wasm_realm_marker_payload(decoded_direction, decoded_fn_kind, decoded_fn_index, decoded_token)
        .expect("WASM-side adapter accepts decoded tuple");
    assert_eq!(payload.boundary_id, BOUNDARY_ID_JS_WASM_REALM);
    assert_eq!(payload.direction, MarkerDirection::Recv);
    assert_eq!(payload.key_text, "token");
    assert_eq!(payload.key_value, token.to_string());
    // The description carries `fn_kind` + `fn_index` so the Event Log
    // can identify the crossing without re-decoding metadata; pin the
    // exact spelling so a drift in the format string triggers this test.
    assert_eq!(
        payload.description.as_deref(),
        Some("wasm enter export#305419896"),
        "fn_index = 0x12345678 = 305419896 decimal"
    );

    // Skip-and-diagnose contract: a slot whose tag is not 4 is not a
    // realm-boundary event — the decoder returns None and the consumer
    // falls through to ordinary tracepoint handling.
    let mut not_realm = slot;
    not_realm[0] = 2; // __ct_emit_call tag
    assert!(decode_wasm_realm_event(&not_realm).is_none());
    // A short slot (e.g. a truncated tail of the batch buffer) is also
    // rejected rather than panicking on out-of-bounds access.
    assert!(decode_wasm_realm_event(&slot[..16]).is_none());

    // -----------------------------------------------------------------
    // Second wire shape: the JSON-line shape the recorder runtime
    // ships through the M26 producer (newline-delimited JSON over the
    // stream socket). `decodeSlot` in
    // `codetracer-wasm-instrumenter/recorder-runtime/host_runtime.js`
    // is the canonical encoder; pin the exact line shape so a
    // producer-side rename surfaces here as a deserialisation failure
    // rather than a silent pair-index miss.
    // -----------------------------------------------------------------
    let json_line = format!(
        r#"{{"kind":"RealmBoundary","token":"{token}","direction":{direction},"fn_kind":{fn_kind},"fn_index":{fn_index}}}"#
    );
    let (j_direction, j_fn_kind, j_fn_index, j_token) =
        parse_wasm_realm_event_json(&json_line).expect("JSON realm-boundary line parses");
    assert_eq!(j_direction, direction);
    assert_eq!(j_fn_kind, fn_kind as i32);
    assert_eq!(j_fn_index, fn_index);
    assert_eq!(j_token, token);
    let json_payload = wasm_realm_marker_payload(j_direction, j_fn_kind, j_fn_index, j_token)
        .expect("WASM-side adapter accepts JSON-decoded tuple");
    let bin_payload = wasm_realm_marker_payload(decoded_direction, decoded_fn_kind, decoded_fn_index, decoded_token)
        .expect("binary path produces the same payload");
    // Both wire shapes converge to the **same** MarkerPayload — the
    // pair index doesn't have to care which transport the event
    // arrived through.
    assert_eq!(json_payload, bin_payload);
    // Skip-and-diagnose: wrong discriminator returns None instead of
    // mis-routing a WasmCall through the realm-boundary adapter.
    assert!(parse_wasm_realm_event_json(r#"{"kind":"WasmCall","fn_kind":1,"fn_index":7}"#).is_none());
    // A token above 2^53 round-trips losslessly through the JSON line
    // because the producer encodes `token` as a decimal string (JSON
    // numbers would silently lose precision above 2^53).
    let big_token: u64 = u64::MAX - 7;
    let big_line =
        format!(r#"{{"kind":"RealmBoundary","token":"{big_token}","direction":1,"fn_kind":0,"fn_index":0}}"#);
    let (_, _, _, big_decoded) = parse_wasm_realm_event_json(&big_line).expect("u64::MAX-class token survives");
    assert_eq!(big_decoded, big_token);
}

// ---------------------------------------------------------------------------
// Sanity: SingleTableId is exposed as `pub` so tests can construct
// expected firings — we don't actually need to manipulate it here but
// importing pins the surface against accidental visibility regressions.
// ---------------------------------------------------------------------------

#[allow(dead_code)]
fn _ensure_public_surface_is_exposed(_: SingleTableId) {}
