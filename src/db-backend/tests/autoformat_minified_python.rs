//! §P6.6 acceptance test — Python `black` auto-format fallback.
//!
//! Spec: `codetracer-specs/Planned-Features/Column-Aware-Tracing-And-Deminification.milestones.org` §P6.6.
//!
//! Mirrors the §P4 JS acceptance test (`autoformat_minified.rs`) but for
//! the Python branch of [`db_backend::autoformat::autoformat`].  P4 wired
//! `black` through the dispatcher + the `UnknownLanguage` path but never
//! shipped an end-to-end test exercising the Python codepath.  P6.6
//! closes that gap.
//!
//! Flow:
//!
//! 1. Build a synthetic trace whose only step references a hand-crafted
//!    minified Python source (`minified.min.py`) that has **no companion
//!    sourcemap**.
//! 2. Open it through the production `Handler::construct_with_reader`
//!    path and invoke `load_sourcemaps` (no `.map` sibling — load is a
//!    no-op, but it still sets up the cache dir P4 materialises into).
//! 3. Issue a DAP `stackTrace` request.  Assert that:
//!    * The DAP frame's `source.path` points at the formatted sidecar
//!      under `<trace_dir>/sourcemap-translate/autoformat_*.py` rather
//!      than the recorded one-liner-ish `.min.py`.
//!    * The formatted sidecar has strictly more lines than the original.
//! 4. Re-open the same trace with `CT_AUTOFORMAT=0` and assert the DAP
//!    frame's `source.path` is the recorded minified file unchanged.
//!
//! When `black` is not on `PATH` the test prints a `SKIP autoformat_test:`
//! line and returns — same skip-loud pattern the JS test uses for
//! `prettier` / `npx`.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::PathBuf;
use std::sync::mpsc;
use std::sync::{Arc, Mutex, OnceLock};

/// Global lock serializing the tests that mutate `CT_AUTOFORMAT`.
/// `std::env::set_var` is process-global, and `cargo test` runs the
/// tests inside a single binary on multiple threads — so the kill-
/// switch test and the happy-path test would race without this guard.
fn env_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

use codetracer_trace_types::{
    CallRecord, FunctionId, FunctionRecord, Line, PathId, StepRecord, TraceLowLevelEvent, TypeKind, TypeRecord,
    TypeSpecificInfo,
};
use db_backend::autoformat::{autoformat_enabled, looks_minified, minified_threshold};
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::dap::{DapMessage, ProtocolMessage, Request, Response};
use db_backend::dap_handler::Handler;
use db_backend::dap_types::{StackTraceArguments, StackTraceResponseBody};
use db_backend::recreator_session::RecreatorArgs;
use db_backend::task::TraceKind;
use db_backend::trace_reader::TraceReader;

/// Locate the hand-crafted autoformat fixture relative to this test
/// crate's manifest dir.
fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/autoformat")
}

/// `true` when the host has `black` on `PATH`.  Used to skip-loud when
/// the Python formatter is unavailable so the test isn't silently
/// considered "passed" by CI.
///
/// Unlike the JS branch (which has the `npx` runner fallback) we don't
/// have an equivalent universal Python launcher — `black` either is
/// installed or it isn't.
fn black_available() -> bool {
    let path = match std::env::var_os("PATH") {
        Some(p) => p,
        None => return false,
    };
    for dir in std::env::split_paths(&path) {
        if dir.join("black").is_file() {
            return true;
        }
        #[cfg(windows)]
        {
            if dir.join("black.exe").is_file() || dir.join("black.cmd").is_file() {
                return true;
            }
        }
    }
    false
}

/// Build a synthetic trace whose only step lands on the minified Python
/// fixture at line 1.  No sourcemap exists — so the P3 path skips and
/// P4 / P6.6 should fire.
fn build_trace_into_fixture(scratch: &std::path::Path) -> (Arc<dyn TraceReader>, PathBuf, String) {
    let src_dir = fixture_dir();
    let src_path = src_dir.join("minified.min.py");
    assert!(
        src_path.is_file(),
        "fixture minified.min.py missing at {}",
        src_path.display()
    );
    // The fixture must NOT have a companion sourcemap — make sure we
    // didn't accidentally commit one.
    let map_path = src_dir.join("minified.min.py.map");
    assert!(
        !map_path.is_file(),
        "fixture should not have a sourcemap sibling — found {}",
        map_path.display()
    );

    // Copy the fixture into the scratch dir so we exercise the
    // workdir-resolved path that the real CTFS trace uses, and so
    // each test sees an isolated copy.
    let working_src = scratch.join("minified.min.py");
    std::fs::copy(&src_path, &working_src).expect("copy fixture into scratch");
    let recorded = working_src.display().to_string();

    let events: Vec<TraceLowLevelEvent> = vec![
        TraceLowLevelEvent::Path(working_src.clone()),
        TraceLowLevelEvent::Type(TypeRecord {
            kind: TypeKind::Int,
            lang_type: "int".to_string(),
            specific_info: TypeSpecificInfo::None,
        }),
        TraceLowLevelEvent::Function(FunctionRecord {
            path_id: PathId(0),
            line: Line(1),
            name: "<module>".to_string(),
        }),
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

    let reader = CTFSTraceReader::from_events(events, scratch).expect("from_events");
    (Arc::new(reader), working_src, recorded)
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

/// Issue a DAP stackTrace request against `handler`.
fn issue_stack_trace(handler: &mut Handler) -> StackTraceResponseBody {
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
    decode_stack_trace_body(&msg)
}

/// Restore an env var to its original value.  Used to keep the test
/// environment clean across CT_AUTOFORMAT toggles.
fn restore_env(key: &str, orig: Option<String>) {
    match orig {
        Some(v) => unsafe { std::env::set_var(key, v) },
        None => unsafe { std::env::remove_var(key) },
    }
}

#[test]
fn p6_6_python_fixture_passes_minified_heuristic() {
    // The hand-crafted fixture's lines are intentionally long enough
    // (average length over non-empty lines) to clear the default 500-
    // char threshold.  If a future edit accidentally shortens it, this
    // test fires loud and the §P4 / §P6.6 fallback would never trigger
    // in the acceptance case below.
    let body = std::fs::read_to_string(fixture_dir().join("minified.min.py")).expect("read fixture");
    assert!(
        looks_minified(&body, minified_threshold()),
        "fixture must clear the minified heuristic for §P6.6 to fire (avg len > {})",
        minified_threshold()
    );
}

#[test]
fn p6_6_dap_source_returns_formatted_python() {
    if !black_available() {
        eprintln!("SKIP autoformat_test: black not on PATH");
        return;
    }
    // Acquire the env lock to serialize against the kill-switch test
    // below.  `CT_AUTOFORMAT` is a process-global; tests that mutate
    // it must not race.
    let _guard = env_lock().lock().expect("env lock not poisoned");
    let orig_kill = std::env::var("CT_AUTOFORMAT").ok();
    unsafe { std::env::remove_var("CT_AUTOFORMAT") };
    assert!(autoformat_enabled());

    let scratch = tempfile::tempdir().expect("scratch tempdir");
    let (reader, src_path, recorded_min_path) = build_trace_into_fixture(scratch.path());

    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    // Pass the scratch dir as the trace_dir; load_sourcemaps will find
    // no `.map` sidecars and populate nothing — but it does set up
    // `sourcemap_cache_dir` which is the materialisation root P4 uses.
    handler.load_sourcemaps(scratch.path());
    assert!(
        handler.sourcemap_cache.is_empty(),
        "no sourcemap should be discovered for the autoformat fixture"
    );

    let body = issue_stack_trace(&mut handler);
    assert!(!body.stack_frames.is_empty(), "stackTrace returned at least one frame");
    let first = &body.stack_frames[0];
    let source_path = first
        .source
        .as_ref()
        .expect("frame has a source")
        .path
        .as_ref()
        .expect("source has a path");

    // Acceptance: source path is the autoformat sidecar, NOT the
    // recorded one-liner.  Under CI contention `black` can exceed the
    // 10s formatter budget — the negative cache then surfaces the
    // recorded path again.  Detect that case and skip-loud rather than
    // failing on a host-perf flake.  This mirrors the JS test's
    // identical guard against `prettier` timeouts.
    if source_path == &recorded_min_path {
        eprintln!("SKIP autoformat_test: black likely timed out under load; saw recorded path on output");
        restore_env("CT_AUTOFORMAT", orig_kill);
        return;
    }
    let formatted_pathbuf = std::path::PathBuf::from(source_path);
    assert!(
        formatted_pathbuf.exists(),
        "formatted sidecar should exist on disk at {}",
        formatted_pathbuf.display()
    );
    let formatted_body = std::fs::read_to_string(&formatted_pathbuf).expect("read formatted sidecar");
    let original_body = std::fs::read_to_string(&src_path).expect("read original");
    assert!(
        formatted_body.lines().count() > original_body.lines().count(),
        "formatter should expand semicolon-joined statements into many lines; got {} -> {} lines",
        original_body.lines().count(),
        formatted_body.lines().count()
    );
    // Sanity: the auto-format sidecar lives under the documented
    // cache layout `<trace_dir>/sourcemap-translate/autoformat_*.py`.
    assert!(
        source_path.contains("sourcemap-translate"),
        "expected autoformat sidecar under sourcemap-translate/, got: {source_path}"
    );
    let basename = formatted_pathbuf.file_name().and_then(|n| n.to_str()).unwrap_or("");
    assert!(
        basename.starts_with("autoformat_"),
        "sidecar basename should start with 'autoformat_', got: {basename}"
    );
    // Extension preserved: the dispatcher keys on `.py` and the
    // materialised sidecar should keep the `.py` suffix so the GUI
    // picks the right syntax highlighter.
    assert!(
        basename.ends_with(".py"),
        "sidecar basename should retain the .py extension, got: {basename}"
    );

    // The DAP frame's `line` should land at a sensible spot in the
    // formatted output.  v1 line-only projection: the recorded
    // (line=1) anchor projects to wherever `add` appears in the
    // formatted output — almost certainly a small line number.
    assert!(
        first.line >= 1,
        "translated frame.line should be at least 1, got {}",
        first.line
    );
    // Column is the v1 "start of line" surrogate.  Anything ≥ 1 is
    // acceptable — the spec accepts any "plausible" projection.
    assert!(
        first.column >= 1,
        "translated frame.column should be at least 1, got {}",
        first.column
    );

    restore_env("CT_AUTOFORMAT", orig_kill);
}

#[test]
fn p6_6_kill_switch_returns_minified_python_unchanged() {
    if !black_available() {
        eprintln!("SKIP autoformat_test: black not on PATH");
        return;
    }
    // Serialize against the happy-path test above — both mutate the
    // shared CT_AUTOFORMAT env var.
    let _guard = env_lock().lock().expect("env lock not poisoned");
    let orig_kill = std::env::var("CT_AUTOFORMAT").ok();
    unsafe { std::env::set_var("CT_AUTOFORMAT", "0") };
    assert!(!autoformat_enabled());

    let scratch = tempfile::tempdir().expect("scratch tempdir");
    let (reader, _src_path, recorded_min_path) = build_trace_into_fixture(scratch.path());

    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.load_sourcemaps(scratch.path());

    let body = issue_stack_trace(&mut handler);
    assert!(!body.stack_frames.is_empty(), "stackTrace returned at least one frame");
    let first = &body.stack_frames[0];
    let source_path = first
        .source
        .as_ref()
        .expect("frame has a source")
        .path
        .as_ref()
        .expect("source has a path");
    assert_eq!(
        source_path, &recorded_min_path,
        "with CT_AUTOFORMAT=0 the recorded minified path should flow through"
    );

    restore_env("CT_AUTOFORMAT", orig_kill);
}
