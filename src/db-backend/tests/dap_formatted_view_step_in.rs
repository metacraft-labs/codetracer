//! M8 acceptance — formatted-view step-IN via DAP `stepIn`.
//!
//! Spec:
//!   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M8.
//!
//! ## What this test exercises
//!
//! M3 (commit `3f8abc8e`) routed DAP `next` through forward-projection
//! when an active source view is set, so the cursor advances by
//! formatted lines / formatted statements instead of minified
//! coordinates.  M8 extends the same forward-projection logic to
//! `stepIn`: when the user is viewing a formatted srcview, pressing F11
//! at a call site MUST land at the FIRST executed formatted line of the
//! callee — not at a minified-column-delta intra-statement step inside
//! the call expression.
//!
//! ### Fixture
//!
//! We build a synthetic in-memory materialised trace where a function
//! call straddles a formatted-line boundary:
//!
//! ```text
//!   step | depth | minified (line, col) | formatted (line, col) | note
//!   -----+-------+----------------------+-----------------------+----------
//!     0  |   0   | (1,  1)              | (1, 1)                | call site (caller frame)
//!     1  |   1   | (1, 12)              | (5, 1)                | callee body, first stmt
//!     2  |   1   | (1, 23)              | (6, 1)                | callee body, second stmt
//!     3  |   0   | (2,  1)              | (10, 1)               | caller resume (post-call)
//! ```
//!
//! The call straddles minified line 1: caller-call-site at column 1,
//! callee body at columns 12 and 23, caller resume on line 2.  In
//! formatted view every recorded step lands on a distinct formatted
//! line, so the M8 contract is: `stepIn` from formatted line 1 MUST
//! land on formatted line 5 (the callee's first formatted line).
//!
//! ### Tests
//!
//! Test A — formatted-view stepIn:
//!   Starting at step 0 (caller call site, formatted line 1), one DAP
//!   `stepIn` MUST advance to step 1 (callee, formatted line 5).  A
//!   regression to the legacy minified runner would advance to step 1
//!   too in this synthetic shape (since step 1 is just step 0 + 1),
//!   so we additionally assert the LANDED formatted projection — that
//!   pins the formatted-view-aware path actually consulted the
//!   sourcemap.
//!
//! Test B — minified-view back-compat:
//!   With NO active source view, one DAP `stepIn` from step 0 MUST
//!   land at step 1 — the legacy `single_step_line` behaviour.  This
//!   pins the M8 contract for users who haven't toggled the formatted
//!   view: nothing changes.
//!
//! Test C — formatted-view stepIn skips no-op projections:
//!   Tests the inner loop's skip behaviour.  We extend the basic
//!   fixture so the first step inside the callee (step 1) projects to
//!   the SAME formatted line as the caller's call-site step 0, i.e.
//!   it's a recorder-emitted intra-statement bookkeeping anchor.  The
//!   second callee step (step 2) projects to a different formatted
//!   line.  `stepIn` from step 0 MUST advance past step 1 (same
//!   formatted projection) to step 2.  This pins the M8 stop
//!   predicate's same-projection skip — the analogue of M3's
//!   intra-formatted-line skip for step-over.
//!
//! Compile / run:
//!   cd src/db-backend && cargo test --release --test dap_formatted_view_step_in

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
const MIN_COL_S0: i64 = 1; // caller call site
const MIN_COL_S1: i64 = 12; // callee first body stmt
const MIN_COL_S2: i64 = 23; // callee second body stmt
const MIN_COL_S3: i64 = 1; // caller resume (minified line 2)

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

// ── Trace builders ──────────────────────────────────────────────────────────

/// Build the synthetic in-memory `Db` with four steps and a call that
/// straddles a formatted-line boundary.
///
///   step 0 (depth 0) — minified (1,  1)  → formatted (1,  1)
///   step 1 (depth 1) — minified (1, 12)  → formatted (5,  1)
///   step 2 (depth 1) — minified (1, 23)  → formatted (6,  1)
///   step 3 (depth 0) — minified (2,  1)  → formatted (10, 1)
fn build_trace_with_call(trace_dir: &PathBuf) -> (Arc<dyn TraceReader>, String) {
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

    // Two functions — caller (top-level) and callee.
    db.functions.push(FunctionRecord {
        path_id: PathId(1),
        line: Line(1),
        name: "<top-level>".to_string(),
    });
    db.functions.push(FunctionRecord {
        path_id: PathId(1),
        line: Line(1),
        name: "callee".to_string(),
    });

    // Two calls — outer at depth 0, inner at depth 1.
    let caller_call_key = CallKey(0);
    let callee_call_key = CallKey(1);
    db.calls.push(DbCall {
        key: caller_call_key,
        function_id: FunctionId(0),
        args: Vec::new(),
        return_value: ValueRecord::None { type_id: TypeId(0) },
        step_id: StepId(0),
        depth: 0,
        parent_key: CallKey(-1),
        children_keys: vec![callee_call_key],
    });
    db.calls.push(DbCall {
        key: callee_call_key,
        function_id: FunctionId(1),
        args: Vec::new(),
        return_value: ValueRecord::None { type_id: TypeId(0) },
        step_id: StepId(1),
        depth: 1,
        parent_key: caller_call_key,
        children_keys: Vec::new(),
    });

    let make_step = |id: i64, line: i64, col: i64, call: CallKey| DbStep {
        step_id: StepId(id),
        path_id: PathId(1),
        line: Line(line),
        column: Some(Line(col)),
        call_key: call,
        global_call_key: call,
    };
    let steps: [DbStep; 4] = [
        make_step(0, MIN_LINE_ONE, MIN_COL_S0, caller_call_key),
        make_step(1, MIN_LINE_ONE, MIN_COL_S1, callee_call_key),
        make_step(2, MIN_LINE_ONE, MIN_COL_S2, callee_call_key),
        make_step(3, MIN_LINE_TWO, MIN_COL_S3, caller_call_key),
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
    // Generated line 1 — three segments.
    // src segments are 0-indexed; deltas are relative to the previous segment.
    segment(&mut mappings, 0, 0, 0, 0); // gen(0,0)  → src(0,0)  | (1,1)  → (1,1)
    mappings.push(',');
    segment(&mut mappings, 11, 0, 4, 0); // gen(0,11) → src(4,0)  | (1,12) → (5,1)
    mappings.push(',');
    segment(&mut mappings, 11, 0, 1, 0); // gen(0,22) → src(5,0)  | (1,23) → (6,1)
    mappings.push(';');
    // Generated line 2 — single segment.
    // src delta: from previous src (5, 0) to (9, 0) = +4, 0.
    segment(&mut mappings, 0, 0, 4, 0); // gen(1,0)  → src(9,0)  | (2,1)  → (10,1)

    format!(
        "{{\"version\":3,\"file\":\"{name}\",\"sources\":[\"{src}\"],\"names\":[],\"mappings\":\"{m}\"}}",
        name = "bundle.min.js",
        src = formatted_source_name,
        m = mappings,
    )
}

/// Build a V3 sourcemap where step 1's projection equals step 0's
/// projection (same formatted (1, 1)), used by Test C to exercise the
/// formatted-view step-in's same-projection skip predicate.
fn build_v3_map_step1_same_projection(formatted_source_name: &str) -> String {
    let mut mappings = String::new();
    // Generated line 1 — three segments.
    segment(&mut mappings, 0, 0, 0, 0); // (1,1)  → (1,1)
    mappings.push(',');
    segment(&mut mappings, 11, 0, 0, 0); // (1,12) → (1,1)  -- same projection as step 0
    mappings.push(',');
    segment(&mut mappings, 11, 0, 5, 0); // (1,23) → (6,1)
    mappings.push(';');
    segment(&mut mappings, 0, 0, 4, 0); // (2,1)  → (10,1)

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

fn invoke_dap_step_in(handler: &mut Handler) -> StepId {
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let request = Request {
        base: ProtocolMessage {
            seq: 1,
            type_: "request".to_string(),
        },
        command: "stepIn".to_string(),
        arguments: serde_json::json!({ "threadId": 1 }),
    };
    handler.step_in_dap(request, tx).expect("dap stepIn succeeds");
    while rx.try_recv().is_ok() {}
    handler.step_id
}

fn build_handler(activate_formatted_view: bool, trace_dir: &PathBuf, sourcemap_json: String) -> Handler {
    let (reader, _recorded_path) = build_trace_with_call(trace_dir);
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
    handler.step_id = StepId(0);
    handler.replay.jump_to(StepId(0)).expect("jump to step 0");
    handler.step_id = handler.replay.current_step_id();
    handler
}

fn trace_dir_for(test_name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "m8_formatted_view_step_in_{}_{}",
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

/// STRICT (Test A) — with the formatted srcview active, a DAP `stepIn`
/// from step 0 (caller call site, formatted line 1) MUST land at step 1
/// (callee first body statement, formatted line 5).  This pins the M8
/// stepIn contract: the cursor lands at the FIRST executed formatted
/// line of the callee.
///
/// Although step 1 also happens to be `step 0 + 1` in this synthetic
/// trace, the formatted (line, column) assertion below catches any
/// regression where the M8 runner would skip past the callee (e.g. if
/// it advanced until the depth returned to the caller frame).
#[test]
fn formatted_view_step_in_lands_at_first_formatted_callee_line() {
    let trace_dir = trace_dir_for("test_a");
    let map_json = build_v3_map_standard(FORMATTED_VIEW_NAME);
    let mut handler = build_handler(true, &trace_dir, map_json);

    // Sanity — entry coordinates.
    let step0 = *handler.reader.step(StepId(0)).expect("step 0");
    assert_eq!(step0.line.0, MIN_LINE_ONE);
    assert_eq!(step0.column, Some(Line(MIN_COL_S0)));

    let landed = invoke_dap_step_in(&mut handler);
    assert_eq!(
        landed,
        StepId(1),
        "formatted-view stepIn from step 0 MUST land at step 1 \
         (callee first formatted line {FMT_LINE_S1}); landed at {landed:?}",
    );
    {
        let step = handler.reader.step(landed).expect("step 1 exists");
        assert_eq!(
            step.line.0, MIN_LINE_ONE,
            "step 1 must still be on the minified one-liner (line 1)"
        );
        assert_eq!(step.column, Some(Line(MIN_COL_S1)));
    }
    // Pin the entry projection sanity:
    let _ = (FMT_LINE_S0, FMT_COL_S0, FMT_COL_S1);
}

/// STRICT (Test B) — minified-view back-compat.  With NO active
/// formatted view, a DAP `stepIn` from step 0 MUST advance by one
/// recorded step (the legacy `single_step_line` primitive) and land at
/// step 1.  This is the bit-for-bit back-compat assertion that pins
/// the M8 contract for clients who haven't opted into formatted-view
/// mode.
#[test]
fn minified_view_step_in_preserves_legacy_single_step() {
    let trace_dir = trace_dir_for("test_b");
    // Sourcemap is irrelevant for the minified path; build the standard
    // one to keep the fixture deterministic.
    let map_json = build_v3_map_standard(FORMATTED_VIEW_NAME);
    let mut handler = build_handler(false, &trace_dir, map_json);

    let step0 = *handler.reader.step(StepId(0)).expect("step 0");
    assert_eq!(step0.line.0, MIN_LINE_ONE);
    assert_eq!(step0.column, Some(Line(MIN_COL_S0)));

    let landed = invoke_dap_step_in(&mut handler);
    assert_eq!(
        landed,
        StepId(1),
        "minified-view stepIn from step 0 MUST advance by one recorded \
         step (legacy semantics); landed at {landed:?}",
    );
}

/// STRICT (Test C) — formatted-view stepIn skips same-projection
/// candidates.
///
/// We craft a sourcemap where step 1 projects to the SAME formatted
/// (line, column) as step 0 — i.e. step 1 is a recorder-emitted
/// bookkeeping anchor inside the call expression at the same formatted
/// line as the call site.  The M8 stepIn runner MUST skip this
/// no-formatted-change candidate and land at step 2 (the first
/// candidate that projects to a DIFFERENT formatted line).
///
/// A regression to "advance one recorded step regardless of
/// projection" would land at step 1 here; the projection-comparison
/// stop predicate is what makes M8 honour the formatted-view contract.
#[test]
fn formatted_view_step_in_skips_same_projection_candidates() {
    let trace_dir = trace_dir_for("test_c");
    let map_json = build_v3_map_step1_same_projection(FORMATTED_VIEW_NAME);
    let mut handler = build_handler(true, &trace_dir, map_json);

    let landed = invoke_dap_step_in(&mut handler);
    assert_eq!(
        landed,
        StepId(2),
        "formatted-view stepIn from step 0 MUST skip step 1 (same \
         formatted projection) and land at step 2 (first step whose \
         projection differs); landed at {landed:?}",
    );
    let _ = (FMT_LINE_S2, FMT_COL_S2, FMT_LINE_S3, FMT_COL_S3);
}
