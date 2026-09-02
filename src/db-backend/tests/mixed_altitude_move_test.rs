//! IS-M2 (db-backend half) — the **real-move-path** application of the IS-M1
//! active-altitude resolver.
//!
//! Spec: `codetracer-specs/Planned-Features/Mixed-Trace-Implicit-Switch.md` §2
//! (P1). Milestone: `codetracer-specs/Recording-Backends/
//! GDScript-Recorder.milestones.org`, IS-Series (IS-M2).
//!
//! # What this proves
//!
//! `mixed_altitude_test.rs` proves the *pure* resolver over hand-settled spans.
//! This file proves the resolver is actually **wired into the DAP move path**:
//! on every move/stop, `Handler::complete_move` computes the active altitude for
//! the landing step from the container's cached crossing spans and surfaces it
//! ADDITIVELY on the `ct/complete-move` event body (`MoveState.activeAltitude` /
//! `MoveState.activeCrossingSpanId`) so the frontend can auto-switch (the
//! frontend half is the deferred IS-M2 slice).
//!
//! We drive the production `Handler` through the public `goto_ticks`
//! (`ct/goto-ticks`) entry point — which lands at an exact step, then emits the
//! same `ct/complete-move` event the GUI consumes — and decode the event body,
//! exactly mirroring how `origin_gdscript_dap_test.rs` builds a materialized
//! handler and reads its DAP responses.
//!
//! # No mocks
//!
//! No mocks. Both fixtures are committed `.ct` containers opened through the
//! production `CTFSTraceReader::open` + `Handler::construct_with_reader(
//! TraceKind::Materialized, …)` path. A missing fixture fails loudly rather than
//! silently skipping.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::mpsc;

use codetracer_trace_types::StepId;
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::dap::{DapMessage, ProtocolMessage, Request};
use db_backend::dap_handler::Handler;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::task::{GoToTicksArguments, TraceKind};
use db_backend::trace_reader::TraceReader;
use serde_json::Value as JsonValue;

// ---------------------------------------------------------------------------
// Fixture plumbing.
// ---------------------------------------------------------------------------

/// The IS-M1 mixed fixture: a materialized GDScript program plus the two nested
/// `gdscript-frame` crossing spans (`compute` [3,6], `scale` [4,5] nested in it).
fn mixed_fixture_ct() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("gdscript_mixed")
        .join("combined_trace.ct")
}

/// A standalone materialized GDScript trace that carries NO crossing spans — the
/// additive-safety control: every altitude must be native and no VM field is
/// surfaced.
fn standalone_fixture_ct() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("gdscript")
        .join("gf_values")
        .join("gdscript_trace.ct")
}

/// Open the committed CTFS container through the production reader.
fn open_reader(ct: &Path) -> Arc<dyn TraceReader> {
    assert!(
        ct.is_file(),
        "fixture trace missing at {} — this test must NOT silently skip",
        ct.display()
    );
    Arc::new(CTFSTraceReader::open(ct).unwrap_or_else(|e| panic!("CTFS open failed for {}: {}", ct.display(), e)))
}

/// Build the same materialized `Handler` `dap_server::setup` builds for a `.ct`
/// launch, plus the IS-M2 crossing-span cache (`load_crossing_spans`) that the
/// production setup path installs after `load_bundled_sources`.
fn build_handler(ct: &Path, reader: Arc<dyn TraceReader>) -> Handler {
    let mut handler = Handler::construct_with_reader(
        TraceKind::Materialized,
        RecreatorArgs::default(),
        Arc::clone(&reader),
        false,
    );
    handler.set_trace_folder(ct);
    handler.load_source_views(ct);
    handler.load_bundled_sources(ct);
    // IS-M2 — cache the container's VM crossing spans so complete_move can
    // compute the active altitude on every move.
    handler.load_crossing_spans(ct);
    handler.initialized = true;
    handler
}

fn make_request(command: &str, args: JsonValue) -> Request {
    Request {
        base: ProtocolMessage {
            seq: 1,
            type_: "request".to_string(),
        },
        command: command.to_string(),
        arguments: args,
    }
}

/// Drive the handler to an exact `step` through the public `ct/goto-ticks` DAP
/// entry point and return the decoded `ct/complete-move` event body (the
/// serialized `MoveState`). For a materialized trace the DAP "ticks" ordinal IS
/// the step id.
fn move_to_step(handler: &mut Handler, step: u64) -> JsonValue {
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let args = GoToTicksArguments {
        thread_id: 0,
        ticks: step as i64,
    };
    let req = make_request("ct/goto-ticks", serde_json::to_value(&args).unwrap());
    handler
        .goto_ticks(req, args, tx)
        .expect("goto_ticks must succeed on a materialized trace");
    // The move path emits a `ct/complete-move` event carrying the MoveState.
    while let Ok(msg) = rx.try_recv() {
        if let DapMessage::Event(event) = msg
            && event.event == "ct/complete-move"
        {
            return event.body;
        }
    }
    panic!("no ct/complete-move event emitted for step {step}");
}

/// The active altitude a move response reports, treating an ABSENT
/// `activeAltitude` as native — the additive default: a trace with no crossing
/// spans omits the field, and its meaning is "native" (spec §2, P1).
fn altitude_of(move_body: &JsonValue) -> String {
    move_body
        .get("activeAltitude")
        .and_then(JsonValue::as_str)
        .unwrap_or("native")
        .to_string()
}

/// The innermost crossing span id a move response reports, or `None` when the
/// field is absent (native altitude / no covering span).
fn crossing_span_of(move_body: &JsonValue) -> Option<u64> {
    move_body.get("activeCrossingSpanId").and_then(JsonValue::as_u64)
}

// ---------------------------------------------------------------------------
// Fixture-integrity guards.
// ---------------------------------------------------------------------------

#[test]
fn test_fixtures_present() {
    assert!(
        mixed_fixture_ct().is_file(),
        "mixed fixture missing at {} — see the fixture README",
        mixed_fixture_ct().display()
    );
    assert!(
        standalone_fixture_ct().is_file(),
        "standalone fixture missing at {}",
        standalone_fixture_ct().display()
    );
}

// ---------------------------------------------------------------------------
// (1) P1 — the move path reports VM inside a crossing span.
// ---------------------------------------------------------------------------

/// Stepping to a step INSIDE a crossing span makes the move response report the
/// VM altitude, naming the INNERMOST covering span. Step 5 sits inside both
/// `compute` [3,6] and `scale` [4,5]; the innermost is `scale` (span id 2).
#[test]
fn test_move_inside_crossing_span_reports_vm() {
    let ct = mixed_fixture_ct();
    let reader = open_reader(&ct);
    let mut handler = build_handler(&ct, Arc::clone(&reader));

    let body = move_to_step(&mut handler, 5);
    assert_eq!(handler.step_id, StepId(5), "goto must land on step 5");
    assert_eq!(
        altitude_of(&body),
        "vm",
        "P1: a covering crossing span => VM on the move response; body={body:?}"
    );
    assert_eq!(
        crossing_span_of(&body),
        Some(2),
        "the innermost covering span at step 5 is `scale` (span id 2); body={body:?}"
    );
}

// ---------------------------------------------------------------------------
// (2) P1 — the move path reports native outside every crossing span.
// ---------------------------------------------------------------------------

/// Stepping to a step OUTSIDE any crossing span makes the move response report
/// native and surface no span id. Step 1 is in the outer `_ready` body, before
/// the `compute` frame [3,6].
#[test]
fn test_move_outside_any_crossing_span_reports_native() {
    let ct = mixed_fixture_ct();
    let reader = open_reader(&ct);
    let mut handler = build_handler(&ct, Arc::clone(&reader));

    let body = move_to_step(&mut handler, 1);
    assert_eq!(handler.step_id, StepId(1), "goto must land on step 1");
    assert_eq!(
        altitude_of(&body),
        "native",
        "P1: no covering crossing span => native on the move response; body={body:?}"
    );
    assert_eq!(
        crossing_span_of(&body),
        None,
        "no crossing span id is surfaced at a native step; body={body:?}"
    );
}

/// The altitude tracks execution across the whole fixture's known step→span
/// layout (see the fixture README): native before/after the `compute` frame, VM
/// throughout [3,6], with the innermost span switching to `scale` (2) inside
/// [4,5] and back to `compute` (1) at step 6.
#[test]
fn test_move_altitude_tracks_full_fixture_layout() {
    let ct = mixed_fixture_ct();
    let reader = open_reader(&ct);
    let mut handler = build_handler(&ct, Arc::clone(&reader));

    // (step, expected altitude, expected innermost span id)
    let expectations: &[(u64, &str, Option<u64>)] = &[
        (0, "native", None),
        (1, "native", None),
        (2, "native", None),
        (3, "vm", Some(1)), // compute frame only
        (4, "vm", Some(2)), // scale nested inside compute
        (5, "vm", Some(2)), // scale nested inside compute
        (6, "vm", Some(1)), // back in compute only
        (7, "native", None),
        (8, "native", None),
    ];
    for &(step, altitude, span) in expectations {
        let body = move_to_step(&mut handler, step);
        assert_eq!(altitude_of(&body), altitude, "altitude at step {step}; body={body:?}");
        assert_eq!(
            crossing_span_of(&body),
            span,
            "innermost span at step {step}; body={body:?}"
        );
    }
}

// ---------------------------------------------------------------------------
// (3) Additive safety — a standalone trace (no crossing spans) is unaffected.
// ---------------------------------------------------------------------------

/// A container with NO span stream leaves `Handler::crossing_spans` empty, so
/// every step's active altitude is native and no VM field is surfaced — the
/// standalone materialized trace is completely unaffected by IS-M2. The optional
/// `activeAltitude` field is even omitted from the wire (skip_serializing_if),
/// so the existing Nim `MoveState` consumer parses unchanged.
#[test]
fn test_standalone_trace_reports_native_for_every_step() {
    let ct = standalone_fixture_ct();
    let reader = open_reader(&ct);
    let mut handler = build_handler(&ct, Arc::clone(&reader));

    // No crossing spans were cached for a standalone container.
    assert!(
        handler.crossing_spans.is_empty(),
        "a standalone trace must cache no VM crossing spans, got {:?}",
        handler.crossing_spans
    );

    let step_count = reader.step_count() as u64;
    assert!(step_count > 0, "standalone fixture must carry steps");
    for step in 0..step_count {
        let body = move_to_step(&mut handler, step);
        assert_eq!(
            altitude_of(&body),
            "native",
            "standalone trace must report native at step {step}; body={body:?}"
        );
        assert_eq!(
            crossing_span_of(&body),
            None,
            "standalone trace must surface no crossing span id at step {step}; body={body:?}"
        );
        // Additive safety: the field is OMITTED, not just set to native.
        assert!(
            body.get("activeAltitude").is_none(),
            "standalone trace must OMIT activeAltitude on the wire (additive); body={body:?}"
        );
    }
}
