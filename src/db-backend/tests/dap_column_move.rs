//! Column-aware DAP test for the **Move** recorder pipeline.
//!
//! Spec:
//!   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M1
//!   (column-aware breakpoint contract — Move slice).
//!
//! Mirrors `dap_column_breakpoint.rs`, but uses column values derived
//! from the canonical `column_aware` Move fixture's debug_info
//! `code_map` so the assertions pin both the Move-recorder→column
//! wire shape and the DAP column-aware filter at once.
//!
//! Fixture (`codetracer-move-recorder/test-programs/move/column_aware/`,
//! `sources/column_aware.move` line 23):
//!
//! ```move
//!         blackbox(&mut v, 100); blackbox(&mut v, 200); blackbox(&mut v, 300);
//! ```
//!
//! `blackbox` routes each argument through a runtime `vector` push so
//! the three calls survive constant folding.  The compiler's
//! `code_map` (in `build/column_aware/debug_info/column_aware.json`)
//! resolves their start bytes (1043, 1066, 1089) to
//! `(line=23, column=9 / 32 / 55)`; byte 1150 (`std::vector::length`
//! on line 24, column 39) and byte 1175 (`assert!` on line 25,
//! column 21) feed the line-only back-compat tests.
//!
//! Compile + run:
//!   cd src/db-backend && cargo test --test dap_column_move

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc;

use codetracer_trace_types::{
    CallKey, FunctionId, FunctionRecord, Line, PathId, StepId, TypeId, TypeKind, TypeRecord, TypeSpecificInfo,
    ValueRecord,
};
use db_backend::dap::{DapMessage, ProtocolMessage, Request};
use db_backend::dap_handler::Handler;
use db_backend::dap_types::{SetBreakpointsArguments, SetBreakpointsResponseBody, Source, SourceBreakpoint};
use db_backend::db::{Db, DbCall, DbStep, EndOfProgram};
use db_backend::in_memory_trace_reader::InMemoryTraceReader;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::task::{Action, StepArg, TraceKind};
use db_backend::trace_reader::TraceReader;

// ── Fixture constants (from `debug_info/column_aware.json`) ────────────────
//
// Pinning these as `const` doubles as a regression guard: a change in
// the recorder's PC→column resolution would flip them and fail the
// test instead of silently producing wrong columns.

/// Source file the recorder maps every PC to.  The DAP layer compares
/// breakpoint source paths against `db.paths`, so the synthetic trace
/// must register a stable path.
const RECORDED_FILE: &str = "column_aware.move";

/// Multi-statement source line — the canonical "three blackbox calls".
const MULTI_LINE: i64 = 23;

/// Columns of `blackbox(&mut v, N)` — resolved from
/// `code_map[pc=4/7/10]` (start bytes 1043, 1066, 1089).
const COL_FIRST: i64 = 9;
const COL_SECOND: i64 = 32;
const COL_THIRD: i64 = 55;

/// Line of `let len = std::vector::length(&v);` — line-only target.
const VEC_LEN_LINE: i64 = 24;

/// Column of the `vec_len` step (`code_map[pc=12]`, start byte 1150).
const COL_VEC_LEN: i64 = 39;

// ── Trace builder ───────────────────────────────────────────────────────────

/// Build an in-memory materialised trace whose steps mirror the
/// `(line, column)` tuples the Move recorder produces for the
/// column_aware fixture's `test_multi_statement_line` function:
///   step 0 — (23,  9)   blackbox(&mut v, 100)
///   step 1 — (23, 32)   blackbox(&mut v, 200)
///   step 2 — (23, 55)   blackbox(&mut v, 300)
///   step 3 — (24, 39)   std::vector::length(&v)
///   step 4 — (25, 21)   assert!(len == 3, E_BAD)   — sentinel
fn build_move_column_aware_trace(trace_dir: &PathBuf) -> (Arc<dyn TraceReader>, String) {
    let recorded = trace_dir.join(RECORDED_FILE).display().to_string();
    let mut db = Db::new(trace_dir);

    // PathId(0) is the reserved sentinel slot used by the CTFS loader.
    // PathId(1) is the absolute recorded path the Move recorder would
    // emit via meta.dat (matching the `find_move_flow_source()` shape).
    db.paths.push(String::new());
    db.paths.push(recorded.clone());
    db.path_map.insert(recorded.clone(), PathId(1));

    db.types.push(TypeRecord {
        kind: TypeKind::Int,
        lang_type: "u64".to_string(),
        specific_info: TypeSpecificInfo::None,
    });

    db.functions.push(FunctionRecord {
        path_id: PathId(1),
        line: Line(MULTI_LINE),
        name: "column_aware::column_aware::test_multi_statement_line".to_string(),
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

    // Per-step `(line, column)` pinned from the column_aware fixture
    // debug_info code_map.  The trailing sentinel on line 25 lets the
    // legacy line-only fallback test distinguish "hit at vec_len" from
    // "ran off the end" — without it, a no-match continue would park
    // at step 3 by accident and the test would silently pass.
    let plan: [(i64, i64); 5] = [
        (MULTI_LINE, COL_FIRST),
        (MULTI_LINE, COL_SECOND),
        (MULTI_LINE, COL_THIRD),
        (VEC_LEN_LINE, COL_VEC_LEN),
        (25, 21), // assert! sentinel — last step
    ];
    let mut step_records: Vec<DbStep> = Vec::with_capacity(plan.len());
    for (idx, (line, col)) in plan.iter().enumerate() {
        let step = DbStep {
            step_id: StepId(idx as i64),
            path_id: PathId(1),
            line: Line(*line),
            column: Some(Line(*col)),
            call_key,
            global_call_key: call_key,
        };
        step_records.push(step);
        db.steps.push(step);
        db.variables.push(Vec::new());
        db.instructions.push(Vec::new());
        db.compound.push(HashMap::new());
        db.cells.push(HashMap::new());
        db.variable_cells.push(HashMap::new());
    }

    // step_map: PathId-indexed list of (line → Vec<DbStep>) maps.  The
    // DAP `setBreakpoints` resolver consults `step_map[path][line]` to
    // bind a breakpoint to candidate steps before applying the column
    // filter on Continue.
    db.step_map.push(HashMap::new()); // sentinel for PathId(0)
    let mut path1_map: HashMap<usize, Vec<DbStep>> = HashMap::new();
    path1_map.insert(
        MULTI_LINE as usize,
        vec![step_records[0], step_records[1], step_records[2]],
    );
    path1_map.insert(VEC_LEN_LINE as usize, vec![step_records[3]]);
    path1_map.insert(25usize, vec![step_records[4]]);
    db.step_map.push(path1_map);

    db.end_of_program = EndOfProgram::Normal;

    let reader: Arc<dyn TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    (reader, recorded)
}

// ── Driver helpers ──────────────────────────────────────────────────────────

/// Issue a DAP `setBreakpoints` request through the production handler.
fn invoke_set_breakpoints(
    handler: &mut Handler,
    path: &str,
    breakpoints: Vec<SourceBreakpoint>,
) -> SetBreakpointsResponseBody {
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let request = Request {
        base: ProtocolMessage {
            seq: 1,
            type_: "request".to_string(),
        },
        command: "setBreakpoints".to_string(),
        arguments: serde_json::json!({}),
    };
    let args = SetBreakpointsArguments {
        source: Source {
            name: None,
            path: Some(path.to_string()),
            source_reference: None,
            presentation_hint: None,
            origin: None,
            sources: None,
            adapter_data: None,
            checksums: None,
        },
        breakpoints: Some(breakpoints),
        source_modified: None,
        lines: None,
    };
    handler
        .set_breakpoints(request, args, tx)
        .expect("set_breakpoints succeeds");
    let msg = rx.recv().expect("response sent");
    let resp = match msg {
        DapMessage::Response(r) => r,
        other => panic!("expected DAP Response, got {other:?}"),
    };
    serde_json::from_value(resp.body.clone()).expect("response body decodes")
}

/// Drive `Handler::step` with `Continue` forward; return the
/// resulting `step_id` and drain notifications.
fn invoke_continue_forward(handler: &mut Handler) -> StepId {
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let request = Request {
        base: ProtocolMessage {
            seq: 2,
            type_: "request".to_string(),
        },
        command: "continue".to_string(),
        arguments: serde_json::json!({}),
    };
    let arg = StepArg {
        action: Action::Continue,
        reverse: false,
        repeat: 0,
        complete: false,
        skip_internal: false,
        skip_no_source: false,
    };
    handler.step(request, arg, tx).expect("continue step succeeds");
    while rx.try_recv().is_ok() {}
    handler.step_id
}

fn make_handler(label: &str) -> (Handler, String) {
    let trace_dir = std::env::temp_dir().join(format!("dap_column_move_{}_{}", label, std::process::id()));
    if !trace_dir.exists() {
        std::fs::create_dir_all(&trace_dir).expect("create trace dir");
    }
    let (reader, recorded_path) = build_move_column_aware_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);
    (handler, recorded_path)
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// STRICT — a `setBreakpoints` request carrying `(line=23, column=32)`
/// MUST stop the next Continue at the SECOND `blackbox` call (step 1).
/// This pins the M1 column-aware contract for the Move recorder
/// pipeline: column values resolved by the Move debug_info code_map
/// participate in the breakpoint key end-to-end.
#[test]
fn column_breakpoint_stops_at_second_blackbox_call() {
    let (mut handler, recorded_path) = make_handler("second");

    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: MULTI_LINE,
            column: Some(COL_SECOND),
            ..Default::default()
        }],
    );

    // Wire-level half: the response MUST echo the bound column so
    // DAP clients can anchor the gutter marker correctly.
    assert_eq!(body.breakpoints.len(), 1);
    let bp = &body.breakpoints[0];
    assert!(bp.verified, "Move column-aware breakpoint must verify: {bp:?}");
    assert_eq!(bp.column, Some(COL_SECOND), "response must echo bound column");
    assert_eq!(bp.line, Some(MULTI_LINE));

    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(1),
        "Continue from step 0 with breakpoint at (line={MULTI_LINE}, col={COL_SECOND}) MUST stop \
         at step 1; landed at {landed:?}.  A line-only fallback would (wrongly) have stopped at \
         step 0 (column {COL_FIRST})."
    );
}

/// STRICT — a `setBreakpoints` request carrying `(line=23, column=55)`
/// MUST skip past the steps at columns 9 and 32 and stop at the THIRD
/// `blackbox` call (step 2).  Guards against the buggy
/// "column-on-response-only" implementation that stores the column on
/// the breakpoint registry but doesn't consult it on the stop check.
#[test]
fn column_breakpoint_skips_earlier_columns_on_same_line() {
    let (mut handler, recorded_path) = make_handler("third");

    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: MULTI_LINE,
            column: Some(COL_THIRD),
            ..Default::default()
        }],
    );
    assert_eq!(body.breakpoints.len(), 1);
    let bp = &body.breakpoints[0];
    assert!(bp.verified);
    assert_eq!(bp.column, Some(COL_THIRD));

    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(2),
        "Continue from step 0 with breakpoint at (line={MULTI_LINE}, col={COL_THIRD}) MUST stop \
         at step 2 (the only step at column {COL_THIRD}); landed at {landed:?}.  A \
         'stored-but-not-consulted' impl would (wrongly) stop at step 1 (col {COL_SECOND})."
    );
}

/// STRICT — legacy back-compat.  A `setBreakpoints` request without a
/// column at `(line=24)` MUST stop at the only step on that line
/// (step 3 — the `std::vector::length` call), and the DAP response
/// MUST report `column=None` so line-only DAP clients aren't lied to.
#[test]
fn line_only_breakpoint_still_stops_at_first_line_step() {
    let (mut handler, recorded_path) = make_handler("legacy");

    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: VEC_LEN_LINE,
            column: None,
            ..Default::default()
        }],
    );
    assert_eq!(body.breakpoints.len(), 1);
    let bp = &body.breakpoints[0];
    assert!(bp.verified, "legacy line-only Move breakpoint must verify");
    assert_eq!(bp.line, Some(VEC_LEN_LINE));
    assert_eq!(
        bp.column, None,
        "legacy line-only breakpoint MUST have column=None on the response"
    );

    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(3),
        "Continue from step 0 with line-only breakpoint at line {VEC_LEN_LINE} MUST stop at \
         step 3 (recorded at column {COL_VEC_LEN}); landed at {landed:?}.  Regression of M1 \
         back-compat would land elsewhere."
    );
}
