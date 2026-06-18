//! Headless DAP test — column-aware breakpoints exercised on the Cairo
//! recorder's `column_aware_test.cairo` fixture column layout.
//!
//! Spec:
//!   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M1
//!   (Cairo adaptation, mirrors the JS / Solana / Noir / PolkaVM siblings).
//!
//! Mirrors `dap_column_breakpoint.rs` (the JS one-liner reference), but
//! pins the column-aware breakpoint contract for the Cairo recorder's
//! column-aware fixture.  The recorder's own integration test
//! (`codetracer-cairo-recorder/tests/test_column_aware.rs`) proves the
//! recorder surfaces three distinct columns on a single line from
//! `test-programs/cairo/column_aware_test.cairo`:
//!
//! ```cairo
//! fn main() -> felt252 {
//!     let a: felt252 = 1; let b: felt252 = 2; let c: felt252 = 3;
//!     a + b + c
//! }
//! ```
//!
//! The body line (line 15 in the fixture) is indented by 4 spaces, so
//! the recorder's `statement_columns_on_line` splitter emits 1-based
//! columns `5`, `25`, `45` — one per `let` statement.  We rebuild that
//! exact column layout as an in-memory materialized trace and drive the
//! production `Handler` through `setBreakpoints` + `continue`, asserting:
//!
//!   1. `setBreakpoints` echoes the bound column on the DAP wire.
//!   2. Continue stops precisely at the step recorded at the bound
//!      `(line, column)` — not at an earlier same-line step at a
//!      different column.
//!   3. Legacy line-only breakpoints still resolve to the first step on
//!      the recorded line.
//!   4. A column-aware breakpoint at the THIRD statement skips the
//!      FIRST and SECOND same-line steps (anti line-only-fallback).
//!
//! Avoiding a runtime recorder dependency: this test uses the synthetic
//! in-memory materialization path (`InMemoryTraceReader`) that the JS,
//! Solana, Noir, and PolkaVM sibling tests established.  The Cairo
//! recorder integration test (`test_column_aware.rs`) already covers
//! the recorder → CTFS column wire; here we exclusively pin the
//! replay / DAP surface against the recorder's documented column layout.
//!
//! Compile/run:
//!   cd src/db-backend && cargo test --test dap_column_cairo

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

/// Recorded file used by the synthetic trace — matches the Cairo
/// recorder's fixture file name so paths look identical to a real
/// recording on disk.
const RECORDED_FILE: &str = "column_aware_test.cairo";

/// Body line carrying the three `let` statements (line 15 of
/// `column_aware_test.cairo`, after the 13-line comment header + the
/// `fn main() -> felt252 {` opener on line 14).
const MULTI_STMT_LINE: i64 = 15;

/// 1-based columns of the three `let` statements on `MULTI_STMT_LINE`,
/// as emitted by the Cairo recorder's `statement_columns_on_line`
/// splitter (see `codetracer-cairo-recorder/src/tracer.rs`).  The body
/// line is indented by 4 spaces, so the first statement begins at
/// column 5; the second after `let a: felt252 = 1; ` at column 25; the
/// third after `let b: felt252 = 2; ` at column 45.
const COL_LET_A: i64 = 5; //  `let a: felt252 = 1;`
const COL_LET_B: i64 = 25; // `let b: felt252 = 2;`
const COL_LET_C: i64 = 45; // `let c: felt252 = 3;`

/// Line carrying the bare `a + b + c` expression at the end of `main`.
/// Used by the legacy line-only assertion — a step somewhere on a later
/// line proves line-only fallback still works.
const SUM_LINE: i64 = 16;

fn build_trace(trace_dir: &PathBuf) -> (Arc<dyn TraceReader>, String) {
    let recorded = trace_dir.join(RECORDED_FILE).display().to_string();
    let mut db = Db::new(trace_dir);

    // PathId(0) is the reserved sentinel slot used by the canonical
    // CTFS loader; PathId(1) is the absolute recorded path.
    db.paths.push(String::new());
    db.paths.push(recorded.clone());
    db.path_map.insert(recorded.clone(), PathId(1));

    db.types.push(TypeRecord {
        kind: TypeKind::Int,
        lang_type: "felt252".to_string(),
        specific_info: TypeSpecificInfo::None,
    });

    // The recorder surfaces `main` at line 14 (the `fn main() -> felt252 {`
    // header).  The function body steps land on subsequent lines.
    db.functions.push(FunctionRecord {
        path_id: PathId(1),
        line: Line(14),
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

    // Four steps mirroring the Cairo recorder column-aware fixture:
    //   0 — line 15, col 5   (`let a: felt252 = 1;`)
    //   1 — line 15, col 25  (`let b: felt252 = 2;`)
    //   2 — line 15, col 45  (`let c: felt252 = 3;`)
    //   3 — line 16, col 5   (`a + b + c` — legacy fallback target)
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
        make_step(3, SUM_LINE, 5),
    ];
    for step in steps.iter() {
        db.steps.push(*step);
        db.variables.push(Vec::new());
        db.instructions.push(Vec::new());
        db.compound.push(HashMap::new());
        db.cells.push(HashMap::new());
        db.variable_cells.push(HashMap::new());
    }

    // step_map indexed by PathId then line.
    db.step_map.push(HashMap::new()); // sentinel for PathId(0)
    let mut path1_map: HashMap<usize, Vec<DbStep>> = HashMap::new();
    path1_map.insert(MULTI_STMT_LINE as usize, vec![steps[0], steps[1], steps[2]]);
    path1_map.insert(SUM_LINE as usize, vec![steps[3]]);
    db.step_map.push(path1_map);

    db.end_of_program = EndOfProgram::Normal;

    let reader: Arc<dyn TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    (reader, recorded)
}

// ── Driver helpers ──────────────────────────────────────────────────────────

/// Issue a DAP `setBreakpoints` request through the production handler
/// and return the decoded response body.
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

/// Drive `Handler::step` forward and return the resulting `step_id`.
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

/// Build a fresh handler + recorded path for a test scope.  The
/// per-test temp directory is keyed on `tag` + pid so concurrent test
/// runs don't stomp each other (mirrors the Noir sibling test).
fn fresh_handler(tag: &str) -> (Handler, String) {
    let trace_dir = std::env::temp_dir().join(format!("dap_column_cairo_{}_{}", tag, std::process::id()));
    if !trace_dir.exists() {
        std::fs::create_dir_all(&trace_dir).expect("create trace dir");
    }
    let (reader, recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);
    (handler, recorded_path)
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// STRICT — a `setBreakpoints` request that carries `column: 25`
/// (the recorded column of `let b: felt252 = 2;` from
/// `column_aware_test.cairo`) MUST stop the next `Continue` at the step
/// recorded at column 25, not at the earlier `let a` step at column 5
/// or the later `let c` step at column 45.
#[test]
fn cairo_column_breakpoint_stops_at_recorded_column() {
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
        "set_breakpoints response MUST echo the bound column ({} expected, got {:?})",
        COL_LET_B,
        bp.column
    );
    assert_eq!(
        bp.line,
        Some(MULTI_STMT_LINE),
        "set_breakpoints response line must echo input"
    );

    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(1),
        "Continue from step 0 with Cairo column breakpoint at (line={}, col={}) MUST stop at step 1 \
         (the only step recorded at column {}); landed at {landed:?}",
        MULTI_STMT_LINE,
        COL_LET_B,
        COL_LET_B
    );
}

/// STRICT — a legacy breakpoint with no column MUST continue to work:
/// Continue from step 0 with breakpoint at `{line: 16}` must stop at
/// the first step on line 16 (the `a + b + c` expression).  This pins
/// back-compat for the Cairo recorder's column-aware fixture.
#[test]
fn cairo_line_only_breakpoint_still_stops_at_line_start() {
    let (mut handler, recorded_path) = fresh_handler("legacy");

    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: SUM_LINE,
            column: None,
            ..Default::default()
        }],
    );
    assert_eq!(body.breakpoints.len(), 1, "exactly one breakpoint in response");
    let bp = &body.breakpoints[0];
    assert!(bp.verified, "legacy line-only breakpoint must verify");
    assert_eq!(bp.line, Some(SUM_LINE));
    assert_eq!(
        bp.column, None,
        "legacy line-only breakpoint MUST have column=None on the response"
    );

    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(3),
        "Continue from step 0 with line-only breakpoint at line {SUM_LINE} MUST stop at step 3 \
         (the only step recorded on that line); landed at {landed:?}"
    );
}

/// STRICT — a column-aware breakpoint MUST NOT match a step on the
/// same line at a different column.  We anchor the breakpoint at the
/// THIRD statement (`let c: felt252 = 3;`) on line 15 — a line-only
/// fallback would (wrongly) stop at step 1 (the first non-current step
/// on line 15).  A correctly column-aware engine MUST skip steps 1 and
/// 2 and land at step 2 (col 45).
#[test]
fn cairo_column_breakpoint_skips_same_line_other_columns() {
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
        "Continue from step 0 with breakpoint at (line={}, col={}) MUST stop at step 2 \
         (the only step recorded at column {}); landed at {landed:?}.  \
         A line-only fallback would (wrongly) have stopped at step 1 (col={}). \
         (col={} = `let a` is documented for completeness.)",
        MULTI_STMT_LINE,
        COL_LET_C,
        COL_LET_C,
        COL_LET_B,
        COL_LET_A,
    );
}
