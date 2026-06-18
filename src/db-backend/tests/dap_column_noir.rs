//! Headless DAP test — column-aware breakpoints on the Noir recorder's
//! `multi_stmt_per_line` fixture column layout.
//!
//! Spec: codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M1.
//!
//! Mirrors `dap_column_breakpoint.rs` (JS) and `dap_column_solana.rs` (SBF)
//! for the Noir fixture at
//! `noir/test_programs/trace/multi_stmt_per_line/src/main.nr`
//! (introduced on the `feature/M-noir-column-aware` branch):
//!
//! ```noir
//! fn main() {
//!     let a: Field = 1; let b: Field = 2; let c: Field = 3;
//!     assert(a + b + c == 6);
//! }
//! ```
//!
//! The Noir tracer records the column at the LHS identifier of each
//! `let` (`Span::start()` → `Files::column_number`).  On line 2 the
//! recorded 1-indexed columns are 9 (`a`), 27 (`b`), 45 (`c`); line 3
//! lands a single step at column 5.  Like `dap_column_solana.rs`, we
//! use the synthetic in-memory materialization path
//! (`InMemoryTraceReader`) to pin the replay/DAP surface against the
//! recorder's documented column layout — the Noir recorder's own
//! integration tests cover the recorder→CTFS column wire.
//!
//! Compile/run: `cd src/db-backend && cargo test --test dap_column_noir`

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

// ── Fixture ─────────────────────────────────────────────────────────────────

/// Recorded file name matching the Noir fixture (so the recorded
/// path mirrors what `nargo trace` emits).
const RECORDED_FILE: &str = "main.nr";

/// Line carrying the three `let` statements (line 2 of
/// `multi_stmt_per_line/src/main.nr`).
const MULTI_STMT_LINE: i64 = 2;

/// 1-based columns of the three `let` LHS identifiers on line 2, as
/// emitted by the Noir column-aware tracer (see the
/// `feature/M-noir-column-aware` branch's
/// `test_multi_stmt_per_line_column_aware` recorder test).
const COL_LET_A: i64 = 9;
const COL_LET_B: i64 = 27;
const COL_LET_C: i64 = 45;

/// Line carrying the `assert(...)` statement — legacy line-only target.
const ASSERT_LINE: i64 = 3;

fn build_trace(trace_dir: &PathBuf) -> (Arc<dyn TraceReader>, String) {
    let recorded = trace_dir.join(RECORDED_FILE).display().to_string();
    let mut db = Db::new(trace_dir);

    // PathId(0) is the reserved CTFS sentinel; PathId(1) is the recorded path.
    db.paths.push(String::new());
    db.paths.push(recorded.clone());
    db.path_map.insert(recorded.clone(), PathId(1));

    db.types.push(TypeRecord {
        kind: TypeKind::Int,
        lang_type: "Field".to_string(),
        specific_info: TypeSpecificInfo::None,
    });

    db.functions.push(FunctionRecord {
        path_id: PathId(1),
        line: Line(1),
        name: "main".to_string(),
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

    // Steps: 0..2 = three `let` LHS positions on line 2; 3 = `assert(...)` on line 3.
    let make_step = |id: i64, line: i64, col: i64| DbStep {
        step_id: StepId(id),
        path_id: PathId(1),
        line: Line(line),
        column: Some(Line(col)),
        call_key,
        global_call_key: call_key,
    };
    let steps: [DbStep; 4] = [
        make_step(0, MULTI_STMT_LINE, COL_LET_A),
        make_step(1, MULTI_STMT_LINE, COL_LET_B),
        make_step(2, MULTI_STMT_LINE, COL_LET_C),
        make_step(3, ASSERT_LINE, 5),
    ];
    for step in steps.iter() {
        db.steps.push(*step);
        db.variables.push(Vec::new());
        db.instructions.push(Vec::new());
        db.compound.push(HashMap::new());
        db.cells.push(HashMap::new());
        db.variable_cells.push(HashMap::new());
    }

    db.step_map.push(HashMap::new()); // sentinel for PathId(0)
    let mut path1_map: HashMap<usize, Vec<DbStep>> = HashMap::new();
    path1_map.insert(MULTI_STMT_LINE as usize, vec![steps[0], steps[1], steps[2]]);
    path1_map.insert(ASSERT_LINE as usize, vec![steps[3]]);
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

/// Drive `Handler::step` with `Continue` forward; return resulting `step_id`.
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

// ── Tests ───────────────────────────────────────────────────────────────────

/// Build a fresh handler + recorded path for a test scope.  The
/// per-test temp directory is keyed on `tag` + pid so concurrent test
/// runs don't stomp each other.
fn fresh_handler(tag: &str) -> (Handler, String) {
    let trace_dir = std::env::temp_dir().join(format!("dap_column_noir_{}_{}", tag, std::process::id()));
    if !trace_dir.exists() {
        std::fs::create_dir_all(&trace_dir).expect("create trace dir");
    }
    let (reader, recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);
    (handler, recorded_path)
}

/// STRICT — `column: 27` (the recorded column of `b`) MUST stop the
/// next Continue at step 1, not at step 0 (col 9 = `a`) or step 2
/// (col 45 = `c`).
#[test]
fn noir_column_breakpoint_stops_at_recorded_column() {
    let (mut handler, recorded_path) = fresh_handler("hit");

    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: MULTI_STMT_LINE,
            column: Some(COL_LET_B),
            ..Default::default()
        }],
    );

    assert_eq!(body.breakpoints.len(), 1, "exactly one breakpoint in response");
    let bp = &body.breakpoints[0];
    assert!(bp.verified, "breakpoint must be verified; response: {bp:?}");
    assert_eq!(
        bp.column,
        Some(COL_LET_B),
        "response MUST echo bound column ({} expected, got {:?})",
        COL_LET_B,
        bp.column
    );
    assert_eq!(bp.line, Some(MULTI_STMT_LINE), "response line must echo input");

    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(1),
        "Continue with column={} MUST stop at step 1; landed at {landed:?}",
        COL_LET_B
    );
}

/// STRICT — legacy line-only breakpoint at line 3 MUST land on step 3
/// (the only step on the `assert(...)` line) and surface column=None
/// on the response.
#[test]
fn noir_line_only_breakpoint_still_stops_at_line_start() {
    let (mut handler, recorded_path) = fresh_handler("legacy");

    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: ASSERT_LINE,
            column: None,
            ..Default::default()
        }],
    );
    assert_eq!(body.breakpoints.len(), 1, "exactly one breakpoint in response");
    let bp = &body.breakpoints[0];
    assert!(bp.verified, "legacy line-only breakpoint must verify");
    assert_eq!(bp.line, Some(ASSERT_LINE));
    assert_eq!(
        bp.column, None,
        "legacy line-only MUST have column=None on the response"
    );

    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(3),
        "Continue with line-only breakpoint at line {ASSERT_LINE} MUST stop at step 3; \
         landed at {landed:?}"
    );
}

/// STRICT — column-aware breakpoint MUST NOT match a same-line step
/// at a different column.  Anchor at column 45 (`c`); a line-only
/// fallback would (wrongly) stop at step 1 (col 27 = `b`, the first
/// non-current step on line 2).
#[test]
fn noir_column_breakpoint_skips_same_line_other_columns() {
    let (mut handler, recorded_path) = fresh_handler("skip");

    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: MULTI_STMT_LINE,
            column: Some(COL_LET_C),
            ..Default::default()
        }],
    );
    assert_eq!(body.breakpoints.len(), 1);
    let bp = &body.breakpoints[0];
    assert!(bp.verified, "column breakpoint at COL_LET_C must verify");
    assert_eq!(bp.column, Some(COL_LET_C));

    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(2),
        "Continue with column={} MUST stop at step 2 (col {}); landed at {landed:?}. \
         Line-only fallback would have stopped at step 1 (col {}).",
        COL_LET_C,
        COL_LET_C,
        COL_LET_B
    );
}
