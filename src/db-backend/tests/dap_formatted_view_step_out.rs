//! M8 acceptance — formatted-view step-OUT via DAP `stepOut`.
//!
//! Spec:
//!   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M8.
//!
//! ## What this test exercises
//!
//! M8's `stepOut` counterpart to the M3-style forward-projection
//! runner.  When the user is inside a function under the active
//! formatted view and presses Shift+F11, the cursor MUST land at the
//! formatted (line, column) where execution resumes in the caller —
//! NOT at the recorded minified anchor (which under the formatted view
//! may project back to the same formatted line as the entry).
//!
//! ### Fixture
//!
//! ```text
//!   step | depth | minified (line, col) | formatted (line, col) | note
//!   -----+-------+----------------------+-----------------------+----------
//!     0  |   0   | (1,  1)              | (1, 1)                | caller call site
//!     1  |   1   | (1, 12)              | (5, 1)                | callee body, first stmt
//!     2  |   1   | (1, 23)              | (6, 1)                | callee body, second stmt
//!     3  |   0   | (2,  1)              | (10, 1)               | caller resume (post-call)
//! ```
//!
//! ### Tests
//!
//! Test A — formatted-view stepOut from callee:
//!   Starting INSIDE the callee at step 1 (formatted line 5, depth 1),
//!   one DAP `stepOut` MUST advance to step 3 (caller resume, formatted
//!   line 10).  This pins the M8 stepOut contract.  Note step 2 sits on
//!   formatted line 6 — a regression that just walked forward one
//!   recorded step would land there (still inside the callee) and the
//!   strict `StepId(3)` assertion would catch it.
//!
//! Test B — minified-view back-compat:
//!   With NO active source view, one DAP `stepOut` from step 1 MUST
//!   walk to one call-depth shallower than the callee frame — i.e.
//!   step 3 (the caller resume), the legacy `step_out` semantic.  This
//!   pins the M8 contract for clients who haven't opted into
//!   formatted-view mode: nothing changes from the legacy behaviour.
//!
//! Test C — formatted-view stepOut skips same-projection caller
//! anchors:
//!   We craft a sourcemap where the caller resume step (step 3) projects
//!   to the SAME formatted (line, column) as the callee entry step
//!   (step 1) — i.e. the recorder anchored the post-call step at a
//!   formatted line that visually sits inside the call expression.
//!   The M8 stepOut runner MUST advance past this same-projection
//!   candidate by walking forward at the post-step-out call depth (or
//!   shallower) until it finds a recorded step whose formatted
//!   projection differs.  Since step 3 is the last recorded step in
//!   the trace, we add a fourth recorded step (step 4) at a different
//!   formatted line so the same-projection skip has a meaningful next
//!   landing.
//!
//! Compile / run:
//!   cd src/db-backend && cargo test --release --test dap_formatted_view_step_out

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
const MIN_LINE_THREE: i64 = 3;

const MIN_COL_S0: i64 = 1;
const MIN_COL_S1: i64 = 12;
const MIN_COL_S2: i64 = 23;
const MIN_COL_S3: i64 = 1;
const MIN_COL_S4: i64 = 1;

const FMT_LINE_S0: u32 = 1;
const FMT_LINE_S1: u32 = 5;
const FMT_LINE_S2: u32 = 6;
const FMT_LINE_S3: u32 = 10;
const FMT_LINE_S4: u32 = 15;

// ── Trace builders ──────────────────────────────────────────────────────────

/// Standard 4-step fixture used by Tests A and B.
fn build_trace_with_call(trace_dir: &PathBuf) -> (Arc<dyn TraceReader>, String) {
    build_trace_inner(trace_dir, /* extra_caller_step = */ false)
}

/// 5-step fixture for Test C — adds an extra caller-frame step at the
/// end so the same-projection-skip path has a recorded step to advance
/// to after the step-out.
fn build_trace_with_call_and_extra_resume(trace_dir: &PathBuf) -> (Arc<dyn TraceReader>, String) {
    build_trace_inner(trace_dir, /* extra_caller_step = */ true)
}

fn build_trace_inner(trace_dir: &PathBuf, extra_caller_step: bool) -> (Arc<dyn TraceReader>, String) {
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
    db.functions.push(FunctionRecord {
        path_id: PathId(1),
        line: Line(1),
        name: "callee".to_string(),
    });

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
    let mut steps: Vec<DbStep> = vec![
        make_step(0, MIN_LINE_ONE, MIN_COL_S0, caller_call_key),
        make_step(1, MIN_LINE_ONE, MIN_COL_S1, callee_call_key),
        make_step(2, MIN_LINE_ONE, MIN_COL_S2, callee_call_key),
        make_step(3, MIN_LINE_TWO, MIN_COL_S3, caller_call_key),
    ];
    if extra_caller_step {
        steps.push(make_step(4, MIN_LINE_THREE, MIN_COL_S4, caller_call_key));
    }
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
    if extra_caller_step {
        path1_map.insert(MIN_LINE_THREE as usize, vec![steps[4]]);
    }
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

/// Standard V3 sourcemap — every recorded step projects to a DISTINCT
/// formatted line:
///   (1,  1)  → (1,  1)
///   (1, 12)  → (5,  1)
///   (1, 23)  → (6,  1)
///   (2,  1)  → (10, 1)
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

/// Test-C V3 sourcemap — the caller resume step (step 3) projects to
/// the SAME formatted (line, column) as the callee first body step
/// (step 1, FMT_LINE_S1).  The fourth recorded step (step 4 in the
/// extended fixture) projects to a different formatted line, giving
/// the same-projection-skip a meaningful landing target.
///
///   (1,  1)  → (1,  1)
///   (1, 12)  → (5,  1)
///   (1, 23)  → (6,  1)
///   (2,  1)  → (5,  1)  ← SAME as step 1 projection
///   (3,  1)  → (15, 1)
fn build_v3_map_resume_same_as_callee_step1(formatted_source_name: &str) -> String {
    let mut mappings = String::new();
    segment(&mut mappings, 0, 0, 0, 0); // (1,1) → (1,1)
    mappings.push(',');
    segment(&mut mappings, 11, 0, 4, 0); // (1,12) → (5,1)
    mappings.push(',');
    segment(&mut mappings, 11, 0, 1, 0); // (1,23) → (6,1)
    mappings.push(';');
    // (2,1) → (5,1).  Previous src was line 5 col 0 (after the (1,23)
    // segment), so delta src_line = -1, src_col = 0.
    segment(&mut mappings, 0, 0, -1, 0);
    mappings.push(';');
    // (3,1) → (15,1).  Previous src (5,0); delta line = +10, col = 0.
    segment(&mut mappings, 0, 0, 10, 0);
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
        content: b"// formatted line 1\n// formatted line 2\n// formatted line 3\n// formatted line 4\n// formatted line 5\n// formatted line 6\n// formatted line 7\n// formatted line 8\n// formatted line 9\n// formatted line 10\n// formatted line 11\n// formatted line 12\n// formatted line 13\n// formatted line 14\n// formatted line 15\n".to_vec(),
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

fn invoke_dap_step_out(handler: &mut Handler) -> StepId {
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let request = Request {
        base: ProtocolMessage {
            seq: 1,
            type_: "request".to_string(),
        },
        command: "stepOut".to_string(),
        arguments: serde_json::json!({ "threadId": 1 }),
    };
    handler.step_out_dap(request, tx).expect("dap stepOut succeeds");
    while rx.try_recv().is_ok() {}
    handler.step_id
}

/// Build a handler with the standard fixture (4 steps) and the chosen
/// sourcemap projection installed.  Cursor is positioned at
/// `start_step_id` so the assertions can drive `stepOut` from the
/// desired callee step.
fn build_handler(
    activate_formatted_view: bool,
    trace_dir: &PathBuf,
    start_step_id: StepId,
    extra_caller_step: bool,
    sourcemap_json: String,
) -> Handler {
    let (reader, _recorded_path) = if extra_caller_step {
        build_trace_with_call_and_extra_resume(trace_dir)
    } else {
        build_trace_with_call(trace_dir)
    };
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
    handler.replay.jump_to(start_step_id).expect("jump to start step");
    handler.step_id = handler.replay.current_step_id();
    handler
}

fn trace_dir_for(test_name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "m8_formatted_view_step_out_{}_{}",
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

/// STRICT (Test A) — with the formatted srcview active and the cursor
/// at step 1 (inside the callee, formatted line 5), one DAP `stepOut`
/// MUST advance to step 3 (the caller's resume step, formatted line
/// 10).  Step 2 (formatted line 6) is also inside the callee — a
/// regression that just advanced one recorded step from step 1 would
/// land there and the strict `StepId(3)` assertion would catch it.
#[test]
fn formatted_view_step_out_lands_at_caller_formatted_resume_line() {
    let trace_dir = trace_dir_for("test_a");
    let map_json = build_v3_map_standard(FORMATTED_VIEW_NAME);
    let mut handler = build_handler(true, &trace_dir, StepId(1), false, map_json);

    // Sanity — entry coordinates.
    let step1 = *handler.reader.step(StepId(1)).expect("step 1");
    assert_eq!(step1.line.0, MIN_LINE_ONE);
    assert_eq!(step1.column, Some(Line(MIN_COL_S1)));

    let landed = invoke_dap_step_out(&mut handler);
    assert_eq!(
        landed,
        StepId(3),
        "formatted-view stepOut from step 1 (inside callee, formatted \
         line {FMT_LINE_S1}) MUST land at step 3 (caller resume, \
         formatted line {FMT_LINE_S3}); landed at {landed:?}",
    );
    {
        let step = handler.reader.step(landed).expect("step 3 exists");
        assert_eq!(
            step.line.0, MIN_LINE_TWO,
            "step 3 must be on the caller resume line (minified line 2)"
        );
        assert_eq!(step.column, Some(Line(MIN_COL_S3)));
    }
    let _ = (FMT_LINE_S0, FMT_LINE_S2, FMT_LINE_S4);
}

/// STRICT (Test B) — minified-view back-compat.  With NO active
/// formatted view, one DAP `stepOut` from step 1 MUST walk one
/// call-depth shallower than the callee frame — i.e. step 3 (the
/// caller resume, depth 0), the legacy `step_out` semantic.  This is
/// the bit-for-bit back-compat assertion.
#[test]
fn minified_view_step_out_preserves_legacy_step_out() {
    let trace_dir = trace_dir_for("test_b");
    let map_json = build_v3_map_standard(FORMATTED_VIEW_NAME);
    let mut handler = build_handler(false, &trace_dir, StepId(1), false, map_json);

    let landed = invoke_dap_step_out(&mut handler);
    assert_eq!(
        landed,
        StepId(3),
        "minified-view stepOut from step 1 MUST advance to step 3 \
         (legacy depth-1 step-out semantic); landed at {landed:?}",
    );
}

/// STRICT (Test C) — formatted-view stepOut skips same-projection
/// caller-resume anchors.
///
/// With the formatted srcview crafted so step 3 projects to the SAME
/// formatted (line, column) as the callee entry step (step 1), the M8
/// stepOut runner MUST advance past step 3 (same projection — no
/// formatted-side change) to step 4 (different formatted line).  This
/// pins the same-projection skip predicate in the formatted-view
/// stepOut runner — the analogue of M3's intra-formatted-line skip for
/// step-over and the M8 step-in case in
/// `dap_formatted_view_step_in.rs::formatted_view_step_in_skips_same_projection_candidates`.
///
/// A regression that landed at step 3 unconditionally (i.e. just
/// reused the legacy `step_out` step id without consulting the
/// formatted projection) would fail the `StepId(4)` assertion.
#[test]
fn formatted_view_step_out_skips_same_projection_caller_anchor() {
    let trace_dir = trace_dir_for("test_c");
    let map_json = build_v3_map_resume_same_as_callee_step1(FORMATTED_VIEW_NAME);
    let mut handler = build_handler(true, &trace_dir, StepId(1), true, map_json);

    let landed = invoke_dap_step_out(&mut handler);
    assert_eq!(
        landed,
        StepId(4),
        "formatted-view stepOut from step 1 MUST skip step 3 (same \
         formatted projection as step 1) and land at step 4 (first \
         caller-frame step whose formatted projection differs); \
         landed at {landed:?}",
    );
    let _ = (FMT_LINE_S0, FMT_LINE_S2, FMT_LINE_S4);
}
