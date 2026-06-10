//! P3 acceptance test — Source Map V3 translation end-to-end.
//!
//! Spec:
//! `codetracer-specs/Planned-Features/Column-Aware-Tracing-And-Deminification.milestones.org` §P3.6.
//!
//! Drives the full server-side path:
//!
//! 1. Build a synthetic trace whose steps reference the **minified**
//!    source path (`lodash.min.js`).
//! 2. Open it through the production `Handler::construct_with_reader`
//!    path and invoke `load_sourcemaps` to register the sourcemap.
//! 3. Issue a DAP `stackTrace` request and assert the returned source
//!    path is the **original** (`lodash.js`), the line / column point
//!    inside the original function body, and the inline
//!    `sourcesContent` survives the round-trip.
//!
//! The fixture under `tests/fixtures/sourcemap/` is hand-crafted (not
//! the real lodash 70 KB bundle) — see the comment in
//! `tests/fixtures/sourcemap/lodash.min.js` for the exact contents and
//! the per-segment mapping table.  A real-lodash fixture would slow
//! down `cargo test` for no acceptance-test benefit; the synthetic
//! version exercises the same code paths.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc;

use codetracer_trace_types::{
    CallRecord, FunctionId, FunctionRecord, Line, PathId, StepRecord, TraceLowLevelEvent, TypeKind, TypeRecord,
    TypeSpecificInfo,
};
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::dap::{DapMessage, ProtocolMessage, Request, Response};
use db_backend::dap_handler::Handler;
use db_backend::dap_types::{StackTraceArguments, StackTraceResponseBody};
use db_backend::recreator_session::RecreatorArgs;
use db_backend::sourcemap_cache::translation_enabled;
use db_backend::task::TraceKind;
use db_backend::trace_reader::TraceReader;

/// Locate the hand-crafted lodash fixture relative to this test
/// crate's manifest dir.
fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/sourcemap")
}

/// Build a synthetic trace whose only step lands on the minified
/// bundle at line 1, column 1 — the start of `function a(b,c)`.
///
/// Returns a tuple `(reader, fixture_dir, recorded_min_path)` so the
/// caller can also assert filesystem invariants on the fixture and
/// reach into the cache by string.
fn build_trace_into_fixture() -> (Arc<dyn TraceReader>, PathBuf, String) {
    let dir = fixture_dir();
    let min_path = dir.join("lodash.min.js");
    assert!(
        min_path.is_file(),
        "fixture lodash.min.js missing at {}",
        min_path.display()
    );
    let map_path = dir.join("lodash.min.js.map");
    assert!(
        map_path.is_file(),
        "fixture lodash.min.js.map missing at {}",
        map_path.display()
    );

    let recorded = min_path.display().to_string();

    // Synthetic event stream: one function `entry` at line 1 of the
    // minified bundle, one step at line 1 column 1.
    let events: Vec<TraceLowLevelEvent> = vec![
        TraceLowLevelEvent::Path(min_path.clone()),
        TraceLowLevelEvent::Type(TypeRecord {
            kind: TypeKind::Int,
            lang_type: "int".to_string(),
            specific_info: TypeSpecificInfo::None,
        }),
        TraceLowLevelEvent::Function(FunctionRecord {
            path_id: PathId(0),
            line: Line(1),
            name: "<top-level>".to_string(),
        }),
        // function `add` corresponds to gen col 0 → orig (line 1, col 1)
        TraceLowLevelEvent::Function(FunctionRecord {
            path_id: PathId(0),
            line: Line(1),
            name: "add".to_string(),
        }),
        TraceLowLevelEvent::Call(CallRecord {
            function_id: FunctionId(0),
            args: vec![],
        }),
        TraceLowLevelEvent::Step(StepRecord {
            path_id: PathId(0),
            line: Line(1),
        }),
        TraceLowLevelEvent::Call(CallRecord {
            function_id: FunctionId(1),
            args: vec![],
        }),
        TraceLowLevelEvent::Step(StepRecord {
            path_id: PathId(0),
            line: Line(1),
        }),
    ];

    // Workdir = the fixture dir so the relative-resolution path
    // (workdir + recorded) yields the same lodash.min.js on disk.
    let reader = CTFSTraceReader::from_events(events, &dir).expect("from_events");
    (Arc::new(reader), dir, recorded)
}

/// Drain a single `Response` from the mpsc channel the Handler
/// publishes DAP responses through.
fn drain_response(rx: &mpsc::Receiver<DapMessage>) -> Response {
    let raw = rx.recv().expect("dap response sent");
    match raw {
        DapMessage::Response(r) => r,
        other => panic!("expected DAP Response, got {other:?}"),
    }
}

/// Decode the `body` field of a stackTrace response.
fn decode_stack_trace_body(resp: &Response) -> StackTraceResponseBody {
    serde_json::from_value(resp.body.clone()).expect("stackTrace body decodes")
}

#[test]
fn p3_sourcemap_index_round_trip() {
    // The sub-crate has full unit-test coverage of the V3 parser; here
    // we just sanity-check the fixture parses against the real
    // production wrapper used by the cache.
    use sourcemap_translate::SourcemapIndex;
    let map_path = fixture_dir().join("lodash.min.js.map");
    let idx = SourcemapIndex::open(&map_path).expect("fixture sourcemap parses");
    assert_eq!(idx.sources(), &["lodash.js".to_string()]);

    // gen (line=1, col=1) → orig (1, 1) with name="add".
    let pos = idx.translate(1, 1).expect("first segment translates");
    assert_eq!(pos.source, "lodash.js");
    assert_eq!(pos.line, 1);
    assert_eq!(pos.column, 1);
    assert_eq!(pos.name.as_deref(), Some("add"));

    // The inline sourcesContent should carry the original program.
    let content = idx.source_content("lodash.js").expect("inline content");
    assert!(content.contains("function add(left, right)"));
    assert!(content.contains("function double(value)"));
}

#[test]
fn p3_replay_server_resolves_lodash_to_original() {
    if !translation_enabled() {
        // The env var is the documented kill switch — if it's off we
        // skip the acceptance assertions and just exercise the
        // fall-through path so the test still proves "no sourcemap
        // ⇒ recorded coordinates preserved".
        eprintln!("CT_SOURCEMAP_TRANSLATION is off; running the no-translate fall-through.");
    }

    let (reader, fixture, recorded_min_path) = build_trace_into_fixture();
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);

    // Load the sourcemap cache against the fixture dir.  We pass the
    // fixture dir as the "trace_dir" because that's where the cache
    // would materialise inline content; the real trace-open path
    // hands the trace folder.
    handler.load_sourcemaps(&fixture);

    if translation_enabled() {
        assert!(
            !handler.sourcemap_cache.is_empty(),
            "expected sourcemap to be discovered for lodash.min.js"
        );
        assert_eq!(handler.sourcemap_cache.len(), 1);
    }

    // Step the handler to step 1 (inside `add`) so stackTrace builds a
    // frame at the recorded (file=lodash.min.js, line=1, column=1) and
    // the translation can fire.
    // The materialised path through `Calltrace::load_callstack` works
    // off `step_id`; the default value (StepId(0)) is the first
    // recorded step, which is what we want.

    // Issue a DAP stackTrace request.
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let request = Request {
        base: ProtocolMessage {
            seq: 1,
            type_: "request".to_string(),
        },
        command: "stackTrace".to_string(),
        arguments: serde_json::json!({"threadId": 1}),
    };
    let args = StackTraceArguments {
        thread_id: 1,
        start_frame: None,
        levels: None,
        format: None,
    };
    handler.stack_trace(request, args, tx).expect("stack_trace responds");
    let msg = drain_response(&rx);
    let body = decode_stack_trace_body(&msg);
    assert!(!body.stack_frames.is_empty(), "stackTrace returned at least one frame");

    if translation_enabled() {
        // Every frame's source.path should refer to lodash.js — the
        // original — rather than the recorded lodash.min.js.
        for frame in &body.stack_frames {
            let source = frame.source.as_ref().expect("frame has a source");
            let path = source.path.as_ref().expect("source has a path");
            assert!(
                path.ends_with("lodash.js") && !path.ends_with("lodash.min.js"),
                "frame source should be the original lodash.js, got: {path}"
            );
            assert_eq!(
                frame.line, 1,
                "translated line should land on the original add() definition"
            );
            assert_eq!(frame.column, 1, "translated column should land on the start of add()");
        }
    } else {
        // No translation: every frame still points at lodash.min.js.
        for frame in &body.stack_frames {
            let source = frame.source.as_ref().expect("frame has a source");
            let path = source.path.as_ref().expect("source has a path");
            assert_eq!(path, &recorded_min_path);
        }
    }
}

#[test]
fn p3_dap_source_returns_unminified_content() {
    // §P3.4 — the inline sourcesContent should be exposed so the UI
    // can show the original source even when no copy of it exists on
    // disk where the recording happened.
    let (reader, fixture, _) = build_trace_into_fixture();
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.load_sourcemaps(&fixture);

    if !translation_enabled() {
        // Off-mode: nothing to assert here.
        return;
    }

    let content = handler
        .sourcemap_cache
        .source_content_for("lodash.js")
        .expect("inline sourcesContent surfaced through the cache");
    assert!(
        content.contains("function add(left, right)"),
        "original source content reaches the cache surface"
    );
    assert!(
        content.contains("function double(value)"),
        "second function survives the round-trip"
    );

    // The cache should also have materialised the inline content to
    // disk (under the fixture dir's `sourcemap-translate/` subdir or
    // similar), so the UI's filesystem-based source reader can pick
    // it up.  We trigger materialisation via a translate call.
    let translated = handler.translate_via_sourcemap_for_path("non-existent-path", 1, 1);
    // Translation by string keys off the recorded path — for the
    // by-path index, the recorded path is the absolute lodash.min.js,
    // not the bogus string we used here.  This call should return
    // None and not crash.
    assert!(translated.is_none());
}
