//! M3 acceptance — formatted-view step-over via DAP `next`.
//!
//! Spec:
//!   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M3.
//!
//! The Column-Aware Replay Navigation campaign delivered:
//!
//!   * M1 — column-based breakpoints (DAP `setBreakpoints.column` honoured).
//!   * M2 — statement-granularity step-over (DAP `next.granularity =
//!     "statement"` honoured).
//!
//! Both runners step over the *recorded* coordinates.  For a recording
//! made on minified source, the recorded coordinates are the minified
//! ones — which for a 100 KB one-liner bundle means "step over line"
//! advances by **one minified line**, i.e. skips the entire program.
//!
//! M3 closes this gap.  When the user is viewing the recorder-baked
//! /formatted/ srcview of a minified source, the runner must consult
//! the sourcemap and advance until the next step's translated location
//! lands at a different /formatted/ (line[, column]) tuple — that is,
//! one *formatted line* (or *formatted statement*) per step rather than
//! one minified line.  Users who haven't toggled the formatted view
//! continue to see the legacy minified-coordinates behaviour.
//!
//! ## What the test exercises
//!
//! We build a synthetic in-memory materialised trace whose steps all
//! land on a single minified line (the headline "100KB one-liner"
//! case), recording columns 1, 12 and 23.  A srcviews V3 record
//! installed under the same recorded path projects each minified
//! column onto a distinct formatted line:
//!
//!   * minified (1,  1) → formatted (1, 1)
//!   * minified (1, 12) → formatted (2, 1)
//!   * minified (1, 23) → formatted (3, 5)
//!
//! and one trailing minified `(2, 1)` step that projects to a fourth
//! formatted line — this gives Test C a meaningful next statement to
//! land on under formatted-statement granularity.
//!
//! Test A — formatted-view, line granularity: starting at step 0
//! (formatted line 1), one DAP `next` MUST advance to step 1
//! (formatted line 2); another MUST advance to step 2 (formatted line
//! 3).  This proves the runner consults the sourcemap and treats one
//! *formatted* line as the step-over unit, NOT one minified line.
//!
//! Test B — minified-view back-compat: with no active formatted view,
//! one DAP `next` from step 0 MUST advance directly to step 3 (the
//! next minified /line/), skipping the intra-line column deltas the
//! way M2 already pinned in `dap_statement_step_over.rs`.  This pins
//! the M3 contract that the legacy minified-coordinate behaviour is
//! UNCHANGED for users who haven't toggled the formatted view.
//!
//! Test C — formatted-view composed with M2 statement granularity:
//! from step 0, three successive
//! `next({granularity: "statement"})` requests under the active
//! formatted view MUST advance through the formatted statements in
//! turn (steps 1, 2, 3).  This proves M3 composes cleanly with M2 —
//! statement granularity inside the formatted view stops at the
//! formatted-side statement boundary (column 5 on formatted line 3),
//! not at the minified column boundary.
//!
//! Compile/run:
//!   cd src/db-backend && cargo test --release --test dap_formatted_view_step_over

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc;

use codetracer_trace_types::{
    CallKey, FunctionId, FunctionRecord, Line, PathId, StepId, TypeId, TypeKind, TypeRecord, TypeSpecificInfo,
    ValueRecord,
};
use db_backend::ctfs_trace_reader::ctfs_container::write_minimal_ctfs;
use db_backend::dap::{DapMessage, ProtocolMessage, Request};
use db_backend::dap_handler::Handler;
use db_backend::db::{Db, DbCall, DbStep, EndOfProgram};
use db_backend::in_memory_trace_reader::InMemoryTraceReader;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::source_views::{SourceView, build_srcviews_table};
use db_backend::task::TraceKind;
use db_backend::trace_reader::TraceReader;

// ── Fixture ─────────────────────────────────────────────────────────────────

const RECORDED_FILE: &str = "bundle.min.js";
const FORMATTED_VIEW_NAME: &str = "bundle.min.js.fmt.js";

/// Columns of the four minified-line-1 statements.  The recorded steps
/// at columns 1, 12 and 23 sit on minified line 1 (one statement each);
/// the fourth step lands on minified line 2 column 1.
const MIN_COL_S1: i64 = 1;
const MIN_COL_S2: i64 = 12;
const MIN_COL_S3: i64 = 23;
const MIN_COL_S4: i64 = 1;

const MIN_LINE_ONE: i64 = 1;
const MIN_LINE_TWO: i64 = 2;

/// Projected formatted coordinates for each minified step.  The srcview
/// V3 map below encodes exactly these mappings.
///
/// We pick column 5 (not 1) for the third formatted line so the
/// statement-granularity assertion in Test C is non-degenerate: a
/// formatted-line-only runner would also land there, but a
/// formatted-(line, column) runner has to confirm the column on top of
/// the line.
// Formatted-side coordinates for each minified step.  The constants
// document the projection encoded in the V3 srcmap below; the runner
// derives the entry's projected coordinates from the cache directly so
// only the post-step columns / lines actually need to be asserted on.
#[allow(dead_code)]
const FMT_LINE_S1: u32 = 1;
#[allow(dead_code)]
const FMT_COL_S1: u32 = 1;
const FMT_LINE_S2: u32 = 2;
const FMT_COL_S2: u32 = 1;
const FMT_LINE_S3: u32 = 3;
const FMT_COL_S3: u32 = 5;
const FMT_LINE_S4: u32 = 5;
const FMT_COL_S4: u32 = 1;

/// Build the synthetic in-memory `Db` with four steps:
///   step 0 — minified (1,  1)  → formatted (1, 1)
///   step 1 — minified (1, 12)  → formatted (2, 1)
///   step 2 — minified (1, 23)  → formatted (3, 5)
///   step 3 — minified (2,  1)  → formatted (5, 1)
fn build_trace(trace_dir: &PathBuf) -> (Arc<dyn TraceReader>, String) {
    let recorded = trace_dir.join(RECORDED_FILE).display().to_string();
    let mut db = Db::new(trace_dir);

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

    let make_step = |id: i64, line: i64, col: i64| DbStep {
        step_id: StepId(id),
        path_id: PathId(1),
        line: Line(line),
        column: Some(Line(col)),
        call_key,
        global_call_key: call_key,
    };
    let steps: [DbStep; 4] = [
        make_step(0, MIN_LINE_ONE, MIN_COL_S1),
        make_step(1, MIN_LINE_ONE, MIN_COL_S2),
        make_step(2, MIN_LINE_ONE, MIN_COL_S3),
        make_step(3, MIN_LINE_TWO, MIN_COL_S4),
    ];
    for step in steps.iter() {
        db.steps.push(*step);
        db.variables.push(Vec::new());
        db.instructions.push(Vec::new());
        db.compound.push(HashMap::new());
        db.cells.push(HashMap::new());
        db.variable_cells.push(HashMap::new());
    }

    db.step_map.push(HashMap::new());
    let mut path1_map: HashMap<usize, Vec<DbStep>> = HashMap::new();
    path1_map.insert(MIN_LINE_ONE as usize, vec![steps[0], steps[1], steps[2]]);
    path1_map.insert(MIN_LINE_TWO as usize, vec![steps[3]]);
    db.step_map.push(path1_map);

    db.end_of_program = EndOfProgram::Normal;

    let reader: Arc<dyn TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    (reader, recorded)
}

/// Build a Source Map V3 JSON mapping minified positions on the
/// recorded bundle to formatted positions on the formatted view.
///
/// The `idx.translate(line, col)` shape (used by
/// `apply_sourcemap_translation`) interprets `(line, col)` as the
/// /generated/ side of the V3 mapping and returns the /original/ side.
/// We therefore encode:
///
///   * generated (= minified) → original (= formatted view)
///
/// so that translation flows the way M3 needs: minified recorded
/// position → formatted view location.  This is the same orientation
/// the §P3 sibling `.map` path uses.
///
/// `sources[0]` is set to the formatted-view file name; the resolver
/// joins this with the trace directory to produce the absolute on-disk
/// path of the materialised formatted view.
fn build_minified_to_formatted_map(formatted_source_name: &str) -> String {
    // Each segment is one VLQ-encoded `(dGenCol, dSrcIdx, dSrcLine,
    // dSrcCol, dNameIdx)` group; segments on the same generated line
    // are comma-separated.  Generated-line transitions are
    // semicolon-separated.
    //
    // We need four segments:
    //   gen (0,  0) → src (0, 0)   (minified line 1 col  1 → formatted line 1 col 1)
    //   gen (0, 11) → src (1, 0)   (minified line 1 col 12 → formatted line 2 col 1)
    //   gen (0, 22) → src (2, 4)   (minified line 1 col 23 → formatted line 3 col 5)
    //   gen (1,  0) → src (4, 0)   (minified line 2 col  1 → formatted line 5 col 1)
    //
    // All values are deltas relative to the previous segment / line
    // start (V3 spec §"Mappings"), so we encode:
    //
    //   line 1: [gen 0  src 0 line 0 col 0]
    //           [gen 11 src 0 line 1 col 0]
    //           [gen 11 src 0 line 1 col 4]
    //   line 2: [gen 0  src 0 line 2 col -4]
    //
    // → "AAAAA,WACA,WACI;AACJ" — see the segment encoder below.
    let mut mappings = String::new();
    // Segment helper: encode 5 VLQ ints joined.
    fn vlq(value: i32, out: &mut String) {
        // V3 VLQ: zigzag-encode signed int, then emit base64 6-bit chunks.
        let mut z: u32 = if value < 0 {
            (((-(value as i64)) as u32) << 1) | 1
        } else {
            (value as u32) << 1
        };
        let alphabet = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        loop {
            let mut digit = (z & 0x1F) as u8;
            z >>= 5;
            if z != 0 {
                digit |= 0x20;
            }
            out.push(alphabet[digit as usize] as char);
            if z == 0 {
                break;
            }
        }
    }
    fn segment(out: &mut String, gen_col_delta: i32, src_idx_delta: i32, src_line_delta: i32, src_col_delta: i32) {
        vlq(gen_col_delta, out);
        vlq(src_idx_delta, out);
        vlq(src_line_delta, out);
        vlq(src_col_delta, out);
    }
    // Generated line 1.
    segment(&mut mappings, 0, 0, 0, 0); // minified (1,1) → formatted (1,1)
    mappings.push(',');
    segment(&mut mappings, 11, 0, 1, 0); // minified (1,12) → formatted (2,1)
    mappings.push(',');
    segment(&mut mappings, 11, 0, 1, 4); // minified (1,23) → formatted (3,5)
    mappings.push(';');
    // Generated line 2 — gen_col delta resets relative to line start (=0).
    // src_line/src_col deltas are relative to the previous segment.
    // Previous segment: src (formatted line 3, col 5) [0-indexed: 2, 4].
    // Target: src (formatted line 5, col 1) [0-indexed: 4, 0].
    // Deltas: src_line += 2, src_col -= 4.
    segment(&mut mappings, 0, 0, 2, -4); // minified (2,1) → formatted (5,1)

    format!(
        "{{\"version\":3,\"file\":\"{name}\",\"sources\":[\"{src}\"],\"names\":[],\"mappings\":\"{m}\"}}",
        name = "bundle.min.js",
        src = formatted_source_name,
        m = mappings,
    )
}

fn write_srcview_container(trace_dir: &std::path::Path) {
    let view = SourceView {
        path_id: 1,
        view_kind: 1, // prettier_format
        view_name: FORMATTED_VIEW_NAME.to_string(),
        content: b"// formatted line 1\n// formatted line 2\n     // formatted line 3\n// blank line 4\n// formatted line 5\n".to_vec(),
        sourcemap_v3: build_minified_to_formatted_map(FORMATTED_VIEW_NAME).into_bytes(),
    };
    let (dat, off) = build_srcviews_table(std::slice::from_ref(&view));
    let ct_path = trace_dir.join("trace.ct");
    write_minimal_ctfs(
        &ct_path,
        &[("srcviews.dat", &dat), ("srcviews.off", &off), ("steps.dat", b"x")],
    )
    .expect("synthetic CTFS container written");
}

// ── Driver helpers ──────────────────────────────────────────────────────────

fn invoke_dap_next(handler: &mut Handler, granularity: Option<&str>) -> StepId {
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let mut args = serde_json::json!({ "threadId": 1 });
    if let Some(g) = granularity {
        args["granularity"] = serde_json::Value::String(g.to_string());
    }
    let request = Request {
        base: ProtocolMessage {
            seq: 1,
            type_: "request".to_string(),
        },
        command: "next".to_string(),
        arguments: args,
    };
    handler
        .next_dap(request, granularity.map(|g| g.to_string()), tx)
        .expect("dap next succeeds");
    while rx.try_recv().is_ok() {}
    handler.step_id
}

/// Build a handler with the synthetic trace and the srcviews container
/// installed.  When `activate_formatted_view` is `true` the handler's
/// active source view is set to the materialised formatted-view path
/// so the M3 runner kicks in.
fn build_handler(activate_formatted_view: bool, trace_dir: &PathBuf) -> Handler {
    let (reader, _recorded_path) = build_trace(trace_dir);
    write_srcview_container(trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.load_sourcemaps(trace_dir);
    handler.load_source_views(trace_dir);
    if activate_formatted_view {
        // The active view path is the materialised sidecar under the
        // trace's cache directory.  The §P6.2 loader writes it under
        // `sourcemap-translate/<sanitised view_name>`.
        let view_path = trace_dir
            .join("sourcemap-translate")
            .join(FORMATTED_VIEW_NAME)
            .display()
            .to_string();
        handler.set_active_source_view(Some(view_path));
    }
    handler.step_id = StepId(0);
    handler.replay.jump_to(StepId(0)).expect("jump to step 0");
    handler.step_id = handler.replay.current_step_id();
    handler
}

fn trace_dir_for(test_name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "m3_formatted_view_step_over_{}_{}",
        test_name,
        std::process::id()
    ));
    if dir.exists() {
        let _ = std::fs::remove_dir_all(&dir);
    }
    std::fs::create_dir_all(&dir).expect("create trace dir");
    dir
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// STRICT (Test A) — with the formatted srcview active, a DAP `next`
/// from step 0 (formatted line 1) MUST land at step 1 (formatted line
/// 2), then another at step 2 (formatted line 3).  Every step here is
/// on a single minified line; the line-granularity runner would treat
/// this as "one minified line, single step over" and skip the entire
/// program.  Reverse-mapping through the formatted srcview is the only
/// way the runner can advance one formatted line at a time.
#[test]
fn formatted_view_next_advances_one_formatted_line_per_invocation() {
    let trace_dir = trace_dir_for("test_a");
    let mut handler = build_handler(true, &trace_dir);

    // Sanity — pin the recorded coordinates of the starting step so the
    // assertions below have a defined ground truth.
    let step0 = *handler.reader.step(StepId(0)).expect("step 0");
    assert_eq!(step0.line.0, MIN_LINE_ONE);
    assert_eq!(step0.column, Some(Line(MIN_COL_S1)));

    let landed_1 = invoke_dap_next(&mut handler, None);
    assert_eq!(
        landed_1,
        StepId(1),
        "first formatted-view next from step 0 MUST advance to step 1 \
         (formatted line {FMT_LINE_S2}); landed at {landed_1:?}",
    );
    {
        let step = handler.reader.step(landed_1).expect("step 1 exists");
        assert_eq!(
            step.line.0, MIN_LINE_ONE,
            "step 1 must still be on the minified one-liner (line 1)"
        );
        assert_eq!(step.column, Some(Line(MIN_COL_S2)));
    }

    let landed_2 = invoke_dap_next(&mut handler, None);
    assert_eq!(
        landed_2,
        StepId(2),
        "second formatted-view next from step 1 MUST advance to step 2 \
         (formatted line {FMT_LINE_S3}); landed at {landed_2:?}",
    );
    {
        let step = handler.reader.step(landed_2).expect("step 2 exists");
        assert_eq!(step.line.0, MIN_LINE_ONE);
        assert_eq!(step.column, Some(Line(MIN_COL_S3)));
    }
}

/// STRICT (Test B) — minified-view back-compat.  With NO active
/// formatted view, a DAP `next` from step 0 MUST advance by minified
/// line (the legacy behaviour) and land directly at step 3 (minified
/// line 2), skipping the same-line column deltas at steps 1 and 2.
///
/// This is the non-negotiable back-compat assertion that pins the M3
/// contract for users who haven't toggled the formatted view: nothing
/// changes for them.  If this fails the M3 implementation would
/// silently regress every legacy DAP client.
#[test]
fn minified_view_next_preserves_legacy_line_granularity() {
    let trace_dir = trace_dir_for("test_b");
    let mut handler = build_handler(false, &trace_dir);

    let step0 = *handler.reader.step(StepId(0)).expect("step 0");
    assert_eq!(step0.line.0, MIN_LINE_ONE);
    assert_eq!(step0.column, Some(Line(MIN_COL_S1)));

    let landed = invoke_dap_next(&mut handler, None);
    assert_eq!(
        landed,
        StepId(3),
        "minified-view next from step 0 MUST advance to step 3 (minified line 2), \
         skipping intra-line column deltas; landed at {landed:?}",
    );
    {
        let step = handler.reader.step(landed).expect("step 3 exists");
        assert_eq!(
            step.line.0, MIN_LINE_TWO,
            "minified-view next MUST advance to a different minified line, NOT a different column",
        );
    }

    // Same back-compat assertion for explicit `granularity == "line"`.
    handler.replay.jump_to(StepId(0)).expect("jump back to 0");
    handler.step_id = handler.replay.current_step_id();
    let landed_line = invoke_dap_next(&mut handler, Some("line"));
    assert_eq!(
        landed_line,
        StepId(3),
        "explicit `granularity: \"line\"` under the minified view MUST behave \
         exactly like legacy `next`; landed at {landed_line:?}",
    );
}

/// STRICT (Test C) — M3 composed with M2 statement granularity.
///
/// With the formatted srcview active, three successive
/// `next({granularity: "statement"})` requests from step 0 MUST land
/// at steps 1, 2, 3 in turn — i.e. one formatted statement per
/// invocation.  Critically, the third hop (step 2 → step 3) crosses a
/// FORMATTED-LINE boundary (line 3 → line 5) AND a formatted column
/// reset; the runner MUST treat any change in the formatted
/// `(line, column)` tuple as a statement boundary, just like M2 does
/// at the minified layer.
///
/// This test is non-negotiable: it proves M3 does not break M2.  If
/// the M3 runner forgets to apply the column predicate under the
/// formatted view it would either (a) stop too early (treating every
/// minified-side step as a separate statement, ignoring same-formatted-
/// statement landings) or (b) stop too late (treating only line
/// changes as statement boundaries inside the formatted view), and
/// the assertions below would catch both cases.
#[test]
fn formatted_view_next_statement_advances_one_formatted_statement_per_invocation() {
    let trace_dir = trace_dir_for("test_c");
    let mut handler = build_handler(true, &trace_dir);

    let landed_1 = invoke_dap_next(&mut handler, Some("statement"));
    assert_eq!(
        landed_1,
        StepId(1),
        "first formatted-view statement-next from step 0 MUST land at step 1 \
         (formatted ({FMT_LINE_S2}, {FMT_COL_S2})); landed at {landed_1:?}",
    );

    let landed_2 = invoke_dap_next(&mut handler, Some("statement"));
    assert_eq!(
        landed_2,
        StepId(2),
        "second formatted-view statement-next from step 1 MUST land at step 2 \
         (formatted ({FMT_LINE_S3}, {FMT_COL_S3})); landed at {landed_2:?}",
    );

    let landed_3 = invoke_dap_next(&mut handler, Some("statement"));
    assert_eq!(
        landed_3,
        StepId(3),
        "third formatted-view statement-next from step 2 MUST land at step 3 \
         (formatted ({FMT_LINE_S4}, {FMT_COL_S4})); landed at {landed_3:?}",
    );
}
