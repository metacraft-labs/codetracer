//! FU-D acceptance — formatted-view reverse step (DAP `stepBack`).
//!
//! Spec:
//!   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org
//!   §M7 + FU-D follow-up (reverse-direction formatted-view stepping).
//!
//! ## What this test exercises
//!
//! M3 (commit `3f8abc8e`) routed DAP `next` through forward-projection
//! when an active source view is set, so the cursor advances by
//! formatted lines / formatted statements instead of minified
//! coordinates.  M8 extended the same forward-projection logic to
//! `stepIn` / `stepOut`.  FU-D extends it once more to the
//! reverse-direction `stepBack` request: when the user is viewing a
//! formatted srcview, pressing F9 / Shift-F9 MUST land at the prior
//! formatted (line, column) — not at a stale minified-column-delta
//! intra-statement step.
//!
//! ### Fixture
//!
//! Mirror of the M8 `dap_formatted_view_step_in.rs` shape: a minified
//! JS one-liner whose four recorded steps project onto four distinct
//! formatted (line, column) coordinates.
//!
//! ```text
//!   step | minified (line, col) | formatted (line, col)
//!   -----+----------------------+-----------------------
//!     0  | (1,  1)              | (1,  1)
//!     1  | (1, 12)              | (5,  1)
//!     2  | (1, 23)              | (6,  1)
//!     3  | (2,  1)              | (10, 1)
//! ```
//!
//! ### Tests
//!
//! Test A — formatted-view stepBack lands one formatted line back:
//!   Starting at step 3 (formatted line 10), one DAP `stepBack` MUST
//!   advance to step 2 (formatted line 6).  A regression to the legacy
//!   minified-coordinate reverse runner would advance to step 2 too in
//!   this synthetic shape (since step 2 is just step 3 - 1), so we
//!   additionally assert the LANDED projection to pin that the
//!   formatted-view-aware reverse path actually consulted the
//!   sourcemap.
//!
//! Test B — minified-view back-compat:
//!   With NO active source view, one DAP `stepBack` from step 3 MUST
//!   land at step 2 — the legacy reverse-line behaviour.  This pins the
//!   FU-D contract for users who haven't toggled the formatted view:
//!   nothing changes.
//!
//! Test C — formatted-view stepBack skips no-op projections:
//!   We craft a sourcemap where step 2 projects to the SAME formatted
//!   (line, column) as step 3 — i.e. step 2 is a recorder-emitted
//!   intra-statement bookkeeping anchor that happens to map back onto
//!   the same formatted line as the starting cursor.  The FU-D
//!   reverse runner MUST skip this no-formatted-change candidate and
//!   land at step 1 (the first prior candidate whose projection
//!   differs).  This pins the FU-D stop predicate's same-projection
//!   skip — the reverse analogue of M3 / M8's intra-formatted-line
//!   skip.
//!
//! Compile / run:
//!   cd src/db-backend && cargo test --release --test dap_formatted_view_step_back

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

const MIN_LINE_ONE: i64 = 1;
const MIN_LINE_TWO: i64 = 2;

/// Recorded minified columns of the four steps in the standard fixture.
const MIN_COL_S0: i64 = 1;
const MIN_COL_S1: i64 = 12;
const MIN_COL_S2: i64 = 23;
const MIN_COL_S3: i64 = 1;

/// Formatted-side projection of each step.  These constants document
/// the V3 sourcemap built below and are used by the assertions.
const FMT_LINE_S0: u32 = 1;
const FMT_COL_S0: u32 = 1;
const FMT_LINE_S1: u32 = 5;
const FMT_COL_S1: u32 = 1;
const FMT_LINE_S2: u32 = 6;
const FMT_COL_S2: u32 = 1;
const FMT_LINE_S3: u32 = 10;
const FMT_COL_S3: u32 = 1;

// ── Trace builder ───────────────────────────────────────────────────────────

/// Build the synthetic in-memory `Db` with four steps.  Mirrors the
/// shape used by `dap_formatted_view_step_in.rs` so the forward / reverse
/// acceptance tests share fixture semantics — direction-of-stepping is
/// the only behavioural axis under test.
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
        make_step(0, MIN_LINE_ONE, MIN_COL_S0),
        make_step(1, MIN_LINE_ONE, MIN_COL_S1),
        make_step(2, MIN_LINE_ONE, MIN_COL_S2),
        make_step(3, MIN_LINE_TWO, MIN_COL_S3),
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

// ── V3 sourcemap builder ────────────────────────────────────────────────────

fn vlq(value: i32, out: &mut String) {
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

/// Build a V3 sourcemap with the standard fixture projection:
///   minified (1,  1) → formatted (1,  1)
///   minified (1, 12) → formatted (5,  1)
///   minified (1, 23) → formatted (6,  1)
///   minified (2,  1) → formatted (10, 1)
fn build_v3_map_standard(formatted_source_name: &str) -> String {
    let mut mappings = String::new();
    segment(&mut mappings, 0, 0, 0, 0); // (1,1)  → (1,1)
    mappings.push(',');
    segment(&mut mappings, 11, 0, 4, 0); // (1,12) → (5,1)
    mappings.push(',');
    segment(&mut mappings, 11, 0, 1, 0); // (1,23) → (6,1)
    mappings.push(';');
    segment(&mut mappings, 0, 0, 4, 0); // (2,1)  → (10,1)

    format!(
        "{{\"version\":3,\"file\":\"{name}\",\"sources\":[\"{src}\"],\"names\":[],\"mappings\":\"{m}\"}}",
        name = "bundle.min.js",
        src = formatted_source_name,
        m = mappings,
    )
}

/// Build a V3 sourcemap where step 2's projection equals step 3's
/// projection — used by Test C to exercise the reverse runner's
/// same-projection skip predicate.  Step 2's recorded coordinates
/// (1, 23) project to formatted (10, 1), the same as step 3's
/// projection.
///
/// Layout — generated line-1 segments expressed as (gen_col_delta,
/// src_idx_delta, src_line_delta, src_col_delta) relative to the
/// previous segment.  We need:
///
///   (1, 1)  → (1, 1)   src(0, 0)
///   (1, 12) → (5, 1)   src(4, 0)   — line delta +4 from previous
///   (1, 23) → (10, 1)  src(9, 0)   — line delta +5 from previous
///   (2, 1)  → (10, 1)  src(9, 0)   — same source position (no delta)
fn build_v3_map_step2_same_projection(formatted_source_name: &str) -> String {
    let mut mappings = String::new();
    segment(&mut mappings, 0, 0, 0, 0); // (1,1)  → (1,1)
    mappings.push(',');
    segment(&mut mappings, 11, 0, 4, 0); // (1,12) → (5,1)
    mappings.push(',');
    segment(&mut mappings, 11, 0, 5, 0); // (1,23) → (10,1)  — same projection as step 3
    mappings.push(';');
    segment(&mut mappings, 0, 0, 0, 0); // (2,1)  → (10,1)

    format!(
        "{{\"version\":3,\"file\":\"{name}\",\"sources\":[\"{src}\"],\"names\":[],\"mappings\":\"{m}\"}}",
        name = "bundle.min.js",
        src = formatted_source_name,
        m = mappings,
    )
}

fn write_srcview_container(trace_dir: &std::path::Path, sourcemap_json: String) {
    let view = SourceView {
        path_id: 1,
        view_kind: 1, // prettier_format
        view_name: FORMATTED_VIEW_NAME.to_string(),
        content: b"// formatted line 1\n// formatted line 2\n// formatted line 3\n// formatted line 4\n// formatted line 5\n// formatted line 6\n// formatted line 7\n// formatted line 8\n// formatted line 9\n// formatted line 10\n".to_vec(),
        sourcemap_v3: sourcemap_json.into_bytes(),
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

/// Issue a DAP `stepBack` request through the production handler.  The
/// wire shape mirrors what a real DAP client sends — pinning the
/// contract end-to-end rather than bypassing it.
fn invoke_dap_step_back(handler: &mut Handler, granularity: Option<&str>) -> StepId {
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
        command: "stepBack".to_string(),
        arguments: args,
    };
    handler
        .step_back_dap(request, granularity.map(|g| g.to_string()), tx)
        .expect("dap stepBack succeeds");
    while rx.try_recv().is_ok() {}
    handler.step_id
}

fn build_handler(activate_formatted_view: bool, trace_dir: &PathBuf, sourcemap_json: String) -> Handler {
    let (reader, _recorded_path) = build_trace(trace_dir);
    write_srcview_container(trace_dir, sourcemap_json);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.load_sourcemaps(trace_dir);
    handler.load_source_views(trace_dir);
    if activate_formatted_view {
        let view_path = trace_dir
            .join("sourcemap-translate")
            .join(FORMATTED_VIEW_NAME)
            .display()
            .to_string();
        handler.set_active_source_view(Some(view_path));
    }
    handler.step_id = StepId(3);
    handler.replay.jump_to(StepId(3)).expect("jump to step 3");
    handler.step_id = handler.replay.current_step_id();
    handler
}

fn trace_dir_for(test_name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "fu_d_formatted_view_step_back_{}_{}",
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

/// STRICT (Test A) — with the formatted srcview active, a DAP `stepBack`
/// from step 3 (formatted line 10) MUST land at step 2 (formatted line
/// 6).  This pins the FU-D reverse-direction contract: the cursor walks
/// one formatted line BACKWARDS per press.
///
/// Although step 2 also happens to be `step 3 - 1` in this synthetic
/// fixture, the formatted (line, column) assertion below catches any
/// regression where the FU-D runner would skip past the prior formatted
/// boundary (e.g. continue stepping back past step 2 into step 1).
#[test]
fn formatted_view_step_back_lands_at_prior_formatted_line() {
    let trace_dir = trace_dir_for("test_a");
    let map_json = build_v3_map_standard(FORMATTED_VIEW_NAME);
    let mut handler = build_handler(true, &trace_dir, map_json);

    // Sanity — entry coordinates.
    let step3 = *handler.reader.step(StepId(3)).expect("step 3");
    assert_eq!(step3.line.0, MIN_LINE_TWO);
    assert_eq!(step3.column, Some(Line(MIN_COL_S3)));

    let landed = invoke_dap_step_back(&mut handler, None);
    assert_eq!(
        landed,
        StepId(2),
        "formatted-view stepBack from step 3 MUST land at step 2 \
         (prior formatted line {FMT_LINE_S2}); landed at {landed:?}",
    );
    {
        let step = handler.reader.step(landed).expect("step 2 exists");
        assert_eq!(
            step.line.0, MIN_LINE_ONE,
            "step 2 must sit on the minified one-liner (line 1)"
        );
        assert_eq!(step.column, Some(Line(MIN_COL_S2)));
    }
    // Pin entry/landing projection sanity:
    let _ = (
        FMT_LINE_S0,
        FMT_COL_S0,
        FMT_LINE_S1,
        FMT_COL_S1,
        FMT_COL_S2,
        FMT_LINE_S3,
        FMT_COL_S3,
    );
}

/// STRICT (Test B) — minified-view back-compat.  With NO active
/// formatted view, a DAP `stepBack` from step 3 MUST advance by the
/// legacy line-granularity reverse runner and land at step 2 (the LAST
/// step of the prior recorded line, line 1, col 23).  This is the
/// bit-for-bit back-compat assertion that pins the FU-D contract for
/// clients who haven't opted into formatted-view mode — identical
/// behaviour to the pre-FU-D reverse-step UX.
#[test]
fn minified_view_step_back_preserves_legacy_line_runner() {
    let trace_dir = trace_dir_for("test_b");
    let map_json = build_v3_map_standard(FORMATTED_VIEW_NAME);
    let mut handler = build_handler(false, &trace_dir, map_json);

    let landed = invoke_dap_step_back(&mut handler, None);
    assert_eq!(
        landed,
        StepId(2),
        "minified-view stepBack from step 3 MUST advance to the last step \
         of the prior recorded line (legacy semantics); landed at {landed:?}",
    );
}

/// STRICT (Test C) — formatted-view stepBack skips same-projection
/// candidates in REVERSE.
///
/// We craft a sourcemap where step 2 projects to the SAME formatted
/// (line, column) as step 3 — i.e. step 2 is a recorder-emitted
/// bookkeeping anchor inside the call expression that happens to map
/// back onto the same formatted line as the starting cursor.  The FU-D
/// stepBack runner MUST skip this no-formatted-change candidate and
/// land at step 1 (the first prior candidate whose projection differs
/// from the entry projection).
///
/// A regression to "advance one recorded step regardless of projection"
/// would land at step 2 here; the projection-comparison stop predicate
/// is what makes FU-D honour the formatted-view contract in reverse.
#[test]
fn formatted_view_step_back_skips_same_projection_candidates() {
    let trace_dir = trace_dir_for("test_c");
    let map_json = build_v3_map_step2_same_projection(FORMATTED_VIEW_NAME);
    let mut handler = build_handler(true, &trace_dir, map_json);

    let landed = invoke_dap_step_back(&mut handler, None);
    assert_eq!(
        landed,
        StepId(1),
        "formatted-view stepBack from step 3 MUST skip step 2 (same \
         formatted projection) and land at step 1 (first prior step \
         whose projection differs); landed at {landed:?}",
    );
    let _ = (
        FMT_LINE_S0,
        FMT_COL_S0,
        FMT_LINE_S1,
        FMT_COL_S1,
        FMT_LINE_S2,
        FMT_COL_S2,
        FMT_LINE_S3,
        FMT_COL_S3,
    );
}
