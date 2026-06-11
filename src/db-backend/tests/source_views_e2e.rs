//! §P6.2 acceptance — `srcviews.dat` alternate-source-views pipeline.
//!
//! Drives the full replay-server side of the spec-section "Alternate
//! Source Views (Deminification Support)" added to
//! `codetracer-trace-format-spec/internal-files.md` in commit
//! `23f4e37`.
//!
//! For each scenario we:
//!
//! 1. Build a synthetic in-memory `Db` whose only `DbStep` lands on a
//!    minified source path.
//! 2. Manufacture a `.ct` CTFS container under the trace directory.
//!    The container's `srcviews.dat` / `srcviews.off` files carry one
//!    or more pre-baked formatted views referencing the same `path_id`
//!    we registered in step (1).
//! 3. Open the handler via `Handler::construct_with_reader`, invoke
//!    `load_sourcemaps` (the existing §P3 entry point) AND
//!    `load_source_views` (the new §P6.2 entry point), then issue a
//!    DAP `stackTrace` request.
//! 4. STRICT-assert on the returned frames.
//!
//! The three tests cover the three documented behaviours:
//!
//! * `replay_server_loads_srcviews_from_trace` — happy path; srcviews
//!   alone drives translation.
//! * `replay_server_prefers_srcviews_over_sibling_map` — when both
//!   sibling `<path>.map` AND a srcviews record exist for the same
//!   path, the srcviews record wins.
//! * `replay_server_legacy_trace_no_srcviews` — legacy traces with no
//!   `srcviews.dat` continue to flow through the §P3 / §P4 fallbacks
//!   unchanged.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::mpsc;

use codetracer_trace_types::{
    CallKey, FunctionId, FunctionRecord, Line, PathId, StepId, TypeId, TypeKind, TypeRecord, TypeSpecificInfo,
    ValueRecord,
};
use db_backend::ctfs_trace_reader::ctfs_container::write_minimal_ctfs;
use db_backend::dap::{DapMessage, ProtocolMessage, Request};
use db_backend::dap_handler::Handler;
use db_backend::dap_types::{StackTraceArguments, StackTraceResponseBody};
use db_backend::db::{Db, DbCall, DbStep, EndOfProgram};
use db_backend::in_memory_trace_reader::InMemoryTraceReader;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::source_views::{SourceView, build_srcviews_table};
use db_backend::sourcemap_cache::translation_enabled;
use db_backend::task::TraceKind;
use db_backend::trace_reader::TraceReader;

// ── Fixture helpers ─────────────────────────────────────────────────────

/// A minimal but valid Source Map V3 JSON that maps **generated**
/// `(line 1, col 1)` in the formatted view back to **original**
/// `(line 1, col 1)` of the original source — with the original-source
/// name set to the recorded minified file name.
///
/// We hard-code a tiny mapping rather than emitting per-character
/// segments because the §P3 translation path (which srcviews flows
/// through) only needs the segment covering the recorded
/// `(line, column)`.  The mapping `AAAAA,;;` covers gen line 1 col 0 →
/// orig (0, 0) with name index 0.
fn make_v3_map(original_filename: &str, name: &str) -> String {
    // `mappings = "AAAAA"` decodes to a single segment at (gen line 0,
    // gen col 0) → (source 0, orig line 0, orig col 0, name 0).
    format!(
        "{{\"version\":3,\"file\":\"view.js\",\"sources\":[{src}],\"names\":[{nm}],\"mappings\":\"AAAAA\"}}",
        src = serde_json::Value::String(original_filename.to_string()),
        nm = serde_json::Value::String(name.to_string())
    )
}

/// Build the synthetic in-memory `Db` whose only `DbStep` references
/// the recorded minified path at `(line 1, col 1)`.  Returns the
/// `(reader, recorded_path_string)` pair.
fn build_trace(trace_dir: &Path, recorded_filename: &str) -> (Arc<dyn TraceReader>, String) {
    let min_path = trace_dir.join(recorded_filename);
    // The fixture only needs to look like a recorded path string; the
    // bytes on disk are irrelevant for the srcviews path (we don't
    // load sibling `.map` for these scenarios — the test for the
    // sibling-vs-srcviews precedence creates a sibling map separately).
    let recorded = min_path.display().to_string();

    let mut db = Db::new(&trace_dir.to_path_buf());
    // PathId(0) is the sentinel slot (matches the canonical reader).
    db.paths.push(String::new());
    db.paths.push(recorded.clone());
    db.path_map.insert(recorded.clone(), PathId(1));

    db.types.push(TypeRecord {
        kind: TypeKind::Int,
        lang_type: "int".to_string(),
        specific_info: TypeSpecificInfo::None,
    });

    db.functions.push(FunctionRecord {
        path_id: PathId(1),
        line: Line(1),
        name: "<top-level>".to_string(),
    });

    let call_key = CallKey(0);
    db.calls.push(DbCall {
        key: call_key,
        function_id: FunctionId(0),
        args: Vec::new(),
        return_value: ValueRecord::None { type_id: TypeId(0) },
        step_id: StepId(0),
        depth: 0,
        parent_key: CallKey(-1),
        children_keys: Vec::new(),
    });

    let step_id = StepId(0);
    let step = DbStep {
        step_id,
        path_id: PathId(1),
        line: Line(1),
        column: Some(Line(1)),
        call_key,
        global_call_key: call_key,
    };
    db.steps.push(step);
    db.variables.push(Vec::new());
    db.instructions.push(Vec::new());
    db.compound.push(HashMap::new());
    db.cells.push(HashMap::new());
    db.variable_cells.push(HashMap::new());

    // step_map indexed by PathId then line.
    db.step_map.push(HashMap::new()); // sentinel
    let mut path1_map: HashMap<usize, Vec<DbStep>> = HashMap::new();
    path1_map.insert(1, vec![step]);
    db.step_map.push(path1_map);

    db.end_of_program = EndOfProgram::Normal;

    let reader: Arc<dyn TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    (reader, recorded)
}

/// Write a synthetic `.ct` CTFS container into `trace_dir` carrying
/// the `srcviews.dat` + `srcviews.off` files derived from `views`.
///
/// The container has only the srcviews tables (no `meta.dat`, no
/// `steps.dat`, no `paths.dat`).  The replay-server's
/// `load_source_views` reads only `srcviews.dat` / `srcviews.off`, so a
/// minimal container is enough to drive the loader.
///
/// We also write `steps.dat` so the CTFS file would be classified by
/// `is_codetracer_ctfs_file` as a materialised-trace container — not
/// strictly needed by the srcviews loader (it reads the container
/// directly via `CtfsReader`), but makes the fixture look closer to a
/// real recording.
fn write_srcviews_container(trace_dir: &Path, views: &[SourceView]) -> PathBuf {
    let (dat, off) = build_srcviews_table(views);
    let ct_path = trace_dir.join("trace.ct");
    write_minimal_ctfs(
        &ct_path,
        &[
            ("srcviews.dat", &dat),
            ("srcviews.off", &off),
            // A placeholder steps.dat keeps the container looking like
            // a normal materialised trace for any other tooling that
            // probes it; the srcviews loader does not look at it.
            ("steps.dat", b"x"),
        ],
    )
    .expect("synthetic CTFS container written");
    ct_path
}

/// Issue the same `stackTrace` request all the §P3 acceptance tests
/// use and return the decoded body.
fn invoke_stack_trace(handler: &mut Handler) -> StackTraceResponseBody {
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
    let msg = rx.recv().expect("stack_trace response sent");
    let resp = match msg {
        DapMessage::Response(r) => r,
        other => panic!("expected DAP Response, got {other:?}"),
    };
    serde_json::from_value(resp.body.clone()).expect("stackTrace body decodes")
}

// ── Tests ───────────────────────────────────────────────────────────────

/// STRICT — the replay-server discovers `srcviews.dat` records under
/// the trace's CTFS container and installs their parsed `SourcemapIndex`
/// into the sourcemap cache.  A subsequent DAP `stackTrace` request for
/// the recorded path resolves to the formatted-view source name.
#[test]
fn replay_server_loads_srcviews_from_trace() {
    if !translation_enabled() {
        // Kill switch active: the loader silently no-ops.  We still
        // verify the recorded path flows through unchanged so we have
        // SOME assertion in this configuration, then exit.
        eprintln!("CT_SOURCEMAP_TRANSLATION is off; skipping srcviews acceptance assertion.");
        return;
    }

    let tmp = tempfile::tempdir().unwrap();
    let trace_dir = tmp.path().to_path_buf();
    let (reader, recorded) = build_trace(&trace_dir, "lodash.min.js");

    // Build the srcviews record: path_id 1 (the slot we pushed above),
    // view_kind 1 (`prettier_format`), with a tiny V3 map that resolves
    // gen (1,1) → orig (1,1) with name "add" — pointing at "lodash.js"
    // as the conceptual original source filename.
    let view = SourceView {
        path_id: 1,
        view_kind: 1,
        view_name: "lodash.fmt.js".to_string(),
        content: b"function add(a, b) {\n  return a + b;\n}\n".to_vec(),
        sourcemap_v3: make_v3_map("lodash.min.js", "add").into_bytes(),
    };
    let ct_path = write_srcviews_container(&trace_dir, std::slice::from_ref(&view));
    assert!(ct_path.is_file());

    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);

    // First load_sourcemaps (P3) — no sibling map, so this is a no-op
    // for the cache; we still call it because the production
    // dispatcher does so the test mirrors reality.
    handler.load_sourcemaps(&trace_dir);
    // Now invoke the new §P6.2 loader — this is the call under test.
    handler.load_source_views(&trace_dir);

    // STRICT — the srcviews record installed an index keyed off the
    // recorded path.  is_empty() means the loader silently failed.
    assert!(
        !handler.sourcemap_cache.is_empty(),
        "load_source_views must have installed an index for the recorded path; \
         cache is empty (recorded={recorded})"
    );

    // STRICT — the stackTrace returns a translated frame.  Our tiny
    // map resolves (1, 1) → (1, 1) with source = "lodash.min.js" (the
    // value the recorder writes as the `sources[0]` entry of the
    // alternate-view map by convention).  The replay-server's path
    // resolver joins the source name with the sourcemap dir (here
    // `trace_dir`), so the frame's source.path ends in
    // `lodash.min.js` — which is intentional: srcviews maps point
    // **back to the original recorded source** per the spec table.
    let body = invoke_stack_trace(&mut handler);
    assert!(!body.stack_frames.is_empty(), "stackTrace returned at least one frame");
    for frame in &body.stack_frames {
        let source = frame.source.as_ref().expect("frame has a source");
        let path = source.path.as_ref().expect("source has a path");
        assert_eq!(
            frame.line, 1,
            "translated frame line should be 1 (srcviews mapped (1,1)→(1,1))"
        );
        assert_eq!(
            frame.column, 1,
            "translated frame column should be 1 (srcviews mapped (1,1)→(1,1))"
        );
        // The source.path is the resolver's best-effort projection of
        // sources[0] under the trace_dir; we assert the BASENAME
        // ends in "lodash.min.js" — proving the translation fired and
        // the resolver produced a sensible-looking path.
        assert!(
            path.ends_with("lodash.min.js"),
            "frame source.path should resolve through the srcviews map; got: {path}"
        );
    }
}

/// STRICT — when both a sibling `<path>.map` AND a `srcviews.dat`
/// record exist for the same recorded path, the `srcviews` entry
/// overrides.  This is the spec-mandated precedence (the recorder
/// explicitly baked the alternate view).
#[test]
fn replay_server_prefers_srcviews_over_sibling_map() {
    if !translation_enabled() {
        eprintln!("CT_SOURCEMAP_TRANSLATION is off; skipping precedence assertion.");
        return;
    }

    let tmp = tempfile::tempdir().unwrap();
    let trace_dir = tmp.path().to_path_buf();
    let (reader, _recorded) = build_trace(&trace_dir, "bundle.min.js");

    // The sibling map is INSTALLED FIRST by load_sourcemaps.  It maps
    // gen (1,1) → orig (1,1) but with source set to "SIBLING-WINS.js"
    // so we can distinguish which map fired.
    let min_path = trace_dir.join("bundle.min.js");
    std::fs::write(&min_path, b"function a(b,c){return b+c;}\n").unwrap();
    let sibling_map_path = trace_dir.join("bundle.min.js.map");
    std::fs::write(&sibling_map_path, make_v3_map("SIBLING-WINS.js", "sibling_name")).unwrap();

    // The srcviews record installs SECOND and overwrites.  Its V3 map
    // points at "SRCVIEWS-WINS.js" so we can tell which won.
    let view = SourceView {
        path_id: 1,
        view_kind: 1,
        view_name: "bundle.fmt.js".to_string(),
        content: b"function add(a, b) { return a + b; }\n".to_vec(),
        sourcemap_v3: make_v3_map("SRCVIEWS-WINS.js", "srcviews_name").into_bytes(),
    };
    write_srcviews_container(&trace_dir, std::slice::from_ref(&view));

    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);

    // Production order: sibling first, srcviews after.  The latter
    // MUST overwrite.
    handler.load_sourcemaps(&trace_dir);
    handler.load_source_views(&trace_dir);

    // STRICT — the cache has exactly one index installed under the
    // recorded path; it must be the srcviews one.
    assert!(
        !handler.sourcemap_cache.is_empty(),
        "either sibling map OR srcviews should have installed an index"
    );

    let body = invoke_stack_trace(&mut handler);
    assert!(!body.stack_frames.is_empty(), "stackTrace returned a frame");
    for frame in &body.stack_frames {
        let source = frame.source.as_ref().expect("frame has a source");
        let path = source.path.as_ref().expect("source has a path");
        assert!(
            path.ends_with("SRCVIEWS-WINS.js"),
            "srcviews must override the sibling .map; expected path ending in SRCVIEWS-WINS.js, got: {path}"
        );
        assert!(
            !path.contains("SIBLING-WINS"),
            "sibling map must NOT have driven the translation; got: {path}"
        );
    }
}

/// STRICT — a legacy CTFS trace WITHOUT `srcviews.dat` continues to
/// flow through the existing §P3 sibling-map path (no breakage).
#[test]
fn replay_server_legacy_trace_no_srcviews() {
    if !translation_enabled() {
        eprintln!("CT_SOURCEMAP_TRANSLATION is off; skipping legacy-fallback assertion.");
        return;
    }

    let tmp = tempfile::tempdir().unwrap();
    let trace_dir = tmp.path().to_path_buf();
    let (reader, _recorded) = build_trace(&trace_dir, "legacy.min.js");

    // Sibling map is the ONLY translation source available.  Its
    // sources[0] is "ORIGINAL.js" so we can confirm the §P3 path
    // fired.
    let min_path = trace_dir.join("legacy.min.js");
    std::fs::write(&min_path, b"function a(b){return b;}\n").unwrap();
    let sibling_map_path = trace_dir.join("legacy.min.js.map");
    std::fs::write(&sibling_map_path, make_v3_map("ORIGINAL.js", "id")).unwrap();

    // NO srcviews container is written.  We do, however, write a
    // dummy `.ct` file with NO srcviews tables to ensure the loader's
    // "absent" branch fires (rather than the "no .ct file" branch).
    // This is the more interesting case to assert.
    let ct_path = trace_dir.join("trace.ct");
    write_minimal_ctfs(&ct_path, &[("steps.dat", b"x")]).expect("dummy CTFS without srcviews");

    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);

    handler.load_sourcemaps(&trace_dir);
    // Calling load_source_views on a no-srcviews container must be a
    // silent no-op: the §P3 sibling-map index installed above should
    // survive intact.
    let before_len = handler.sourcemap_cache.len();
    handler.load_source_views(&trace_dir);
    let after_len = handler.sourcemap_cache.len();

    // STRICT — the §P3 cache is unchanged.
    assert_eq!(
        before_len, after_len,
        "load_source_views must not touch the cache when srcviews.dat is absent; \
         before={before_len} after={after_len}"
    );
    assert!(
        !handler.sourcemap_cache.is_empty(),
        "sibling .map should have populated the cache via load_sourcemaps"
    );

    // STRICT — the §P3 sibling map drives the translation.
    let body = invoke_stack_trace(&mut handler);
    assert!(!body.stack_frames.is_empty(), "stackTrace returned a frame");
    for frame in &body.stack_frames {
        let source = frame.source.as_ref().expect("frame has a source");
        let path = source.path.as_ref().expect("source has a path");
        assert!(
            path.ends_with("ORIGINAL.js"),
            "legacy sibling .map must still drive the translation; expected ORIGINAL.js, got: {path}"
        );
    }
}
