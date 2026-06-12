//! M1 acceptance — column-aware breakpoints on `(path, line, column)`.
//!
//! Spec:
//!   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M1.
//!
//! The Column-Aware Tracing & Source Deminification campaign delivered
//! /recording/ of column data. CodeTracer's replay engine, however, is
//! still line-only at the breakpoint surface: the DAP `setBreakpoints`
//! request ignores `column`, and the Continue stop check compares only
//! `(path, line)` against `DbStep`. This file pins the M1 requirement
//! that:
//!
//!   1. The DAP `setBreakpoints` response surfaces the bound column
//!      (instead of unconditional `null`).
//!   2. The breakpoint registry stores the column alongside the line.
//!   3. The Continue stop check matches column when a column was set
//!      and falls back to line-only matching when no column was set.
//!   4. Legacy line-only breakpoints continue to work end-to-end —
//!      i.e. they stop at the first step on the recorded line, with
//!      any recorded column.
//!
//! ## What the test exercises
//!
//! We build a synthetic in-memory materialized trace whose steps land
//! on a minified JS one-liner at three distinct columns on line 1:
//!
//!   * step 0  — line 1, column 1   (e.g. `const a = 1;`)
//!   * step 1  — line 1, column 14  (`const b = 2;`)
//!   * step 2  — line 1, column 28  (`const c = a + b;`)
//!   * step 3  — line 5, column 1   (a separate later statement)
//!
//! Then we drive the DAP `setBreakpoints` handler with a request that
//! carries `{line: 1, column: 14}`. After Continue (forward) from
//! step 0, the handler MUST be parked at step 1 — the only step whose
//! `(line, column)` matches the breakpoint coordinates.
//!
//! For the legacy-fallback variant we register a column-less breakpoint
//! at `{line: 5}`. After Continue from step 0, the handler MUST be
//! parked at step 3 (the only step on line 5), proving that omitting
//! `column` still resolves to the line-only match.
//!
//! Compile/run:
//!   cd src/db-backend && cargo test --test dap_column_breakpoint
//!
//! Bypass routes (env-var overrides, format flags, etc.) are NOT
//! tolerated by this test — the assertions all fire on the production
//! `Handler` code path.

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

/// Recorded path used by the synthetic trace.  The fixture's "source"
/// is the headline minified-JS one-liner the M1 spec calls out:
/// `const a = 1; const b = 2; const c = a + b;`.  The actual on-disk
/// file contents are irrelevant for the DAP layer's set/continue path;
/// only the recorded `(path, line, column)` tuples on the DbSteps are
/// consulted.
const RECORDED_FILE: &str = "bundle.min.js";

/// Columns of the three statements on line 1, mirroring where the
/// recorder would land a step at the start of each statement.
const COL_A: i64 = 1; // `const a = 1;`
const COL_B: i64 = 14; // `const b = 2;`
const COL_C: i64 = 28; // `const c = a + b;`

/// A later, line-only step that the legacy-fallback case lands on.
const LATER_LINE: i64 = 5;

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

    // Four steps:
    //   0 — line 1, col 1
    //   1 — line 1, col 14
    //   2 — line 1, col 28
    //   3 — line 5, col 1  (legacy-fallback target)
    let make_step = |id: i64, line: i64, col: i64| DbStep {
        step_id: StepId(id),
        path_id: PathId(1),
        line: Line(line),
        column: Some(Line(col)),
        call_key,
        global_call_key: call_key,
    };
    let steps: [DbStep; 4] = [
        make_step(0, 1, COL_A),
        make_step(1, 1, COL_B),
        make_step(2, 1, COL_C),
        make_step(3, LATER_LINE, 1),
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
    db.step_map.push(HashMap::new()); // sentinel
    let mut path1_map: HashMap<usize, Vec<DbStep>> = HashMap::new();
    path1_map.insert(1, vec![steps[0], steps[1], steps[2]]);
    path1_map.insert(LATER_LINE as usize, vec![steps[3]]);
    db.step_map.push(path1_map);

    db.end_of_program = EndOfProgram::Normal;

    let reader: Arc<dyn TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    (reader, recorded)
}

// ── Driver helpers ──────────────────────────────────────────────────────────

/// Issue a DAP `setBreakpoints` request through the production handler
/// and return the decoded response body.  Mirrors the request shape a
/// real DAP client would send.
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

/// Drive the production `Handler::step` with `Continue` forward and
/// return the resulting `step_id`.  Drains any notifications the
/// handler emits during the move so the channel is fully consumed.
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
    // Drain everything: response + any notifications.
    while rx.try_recv().is_ok() {}
    handler.step_id
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// STRICT — a `setBreakpoints` request that carries `column: 14` MUST
/// stop the next `Continue` at the step recorded at column 14 — not at
/// the earlier same-line steps at columns 1 / 28.  This is the M1 core
/// requirement: column participates in the breakpoint key end-to-end.
#[test]
fn column_breakpoint_stops_at_recorded_column() {
    let trace_dir = std::env::temp_dir().join(format!("dap_column_breakpoint_test_{}", std::process::id()));
    if !trace_dir.exists() {
        std::fs::create_dir_all(&trace_dir).expect("create trace dir");
    }
    let (reader, recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);

    // ── Set the column-aware breakpoint ────────────────────────────
    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: 1,
            column: Some(COL_B),
            ..Default::default()
        }],
    );

    // STRICT — the DAP response MUST surface the bound column (not the
    // unconditional `null` the legacy implementation returned).  This
    // is the wire-level half of the M1 contract — DAP clients (VS Code,
    // the GUI, headless test rigs) all consume `Breakpoint.column` to
    // anchor the gutter marker.
    assert_eq!(body.breakpoints.len(), 1, "exactly one breakpoint in response");
    let bp = &body.breakpoints[0];
    assert!(bp.verified, "breakpoint must be verified; response: {bp:?}");
    assert_eq!(
        bp.column,
        Some(COL_B),
        "set_breakpoints response MUST echo the bound column ({} expected, got {:?})",
        COL_B,
        bp.column
    );
    assert_eq!(bp.line, Some(1), "set_breakpoints response line must echo input");

    // ── Continue must stop precisely at (line=1, col=14) ───────────
    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(1),
        "Continue from step 0 with breakpoint at (line=1, col=14) MUST stop at step 1 \
         (the only step recorded at column 14); landed at {landed:?}"
    );
}

/// STRICT — a legacy breakpoint with no column (the existing
/// line-only behaviour) MUST keep working: Continue from step 0 with
/// breakpoint at `{line: 5}` must stop at the first step on line 5.
/// This pins the back-compat half of the M1 contract — the milestone
/// extends the key but does not break the existing semantics.
#[test]
fn line_only_breakpoint_still_stops_at_line_start() {
    let trace_dir = std::env::temp_dir().join(format!("dap_column_breakpoint_legacy_test_{}", std::process::id()));
    if !trace_dir.exists() {
        std::fs::create_dir_all(&trace_dir).expect("create trace dir");
    }
    let (reader, recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);

    // Legacy DAP request — no column on the SourceBreakpoint.  This is
    // exactly what a line-only DAP client (e.g. older VS Code, the
    // current CodeTracer Electron frontend before M1) sends.
    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: LATER_LINE,
            column: None,
            ..Default::default()
        }],
    );
    assert_eq!(body.breakpoints.len(), 1, "exactly one breakpoint in response");
    let bp = &body.breakpoints[0];
    assert!(bp.verified, "legacy line-only breakpoint must verify");
    assert_eq!(bp.line, Some(LATER_LINE));
    // A line-only breakpoint MUST NOT spuriously surface a column on
    // the response.  This guarantees DAP clients aren't lied to.
    assert_eq!(
        bp.column, None,
        "legacy line-only breakpoint MUST have column=None on the response"
    );

    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(3),
        "Continue from step 0 with line-only breakpoint at line {LATER_LINE} MUST stop at step 3 \
         (the only step recorded on that line); landed at {landed:?}"
    );
}

/// STRICT — a column-aware breakpoint MUST NOT match a step on the
/// same line at a different column.  This guards against the
/// "weakened" interpretation where the engine quietly falls back to
/// line-only matching whenever a column is set.  Without this test a
/// trivially-wrong implementation that just stores the column without
/// consulting it on the stop check would pass the first test (because
/// step 1 happens to be the first step on line 1).
#[test]
fn column_breakpoint_skips_same_line_other_columns() {
    let trace_dir = std::env::temp_dir().join(format!("dap_column_breakpoint_skip_test_{}", std::process::id()));
    if !trace_dir.exists() {
        std::fs::create_dir_all(&trace_dir).expect("create trace dir");
    }
    let (reader, recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);

    // Breakpoint at (line=1, col=28) — the *third* statement.  A
    // line-only fallback would (wrongly) stop at step 1, the first
    // step on line 1.  A correctly column-aware engine MUST skip
    // steps 1 and 2 and land at step 2 itself (the only step at
    // col 28).
    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: 1,
            column: Some(COL_C),
            ..Default::default()
        }],
    );
    assert_eq!(body.breakpoints.len(), 1);
    let bp = &body.breakpoints[0];
    assert!(bp.verified, "column breakpoint at COL_C must verify");
    assert_eq!(bp.column, Some(COL_C));

    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(2),
        "Continue from step 0 with breakpoint at (line=1, col={COL_C}) MUST stop at step 2 \
         (the only step recorded at column {COL_C}); landed at {landed:?}.  \
         A line-only fallback would (wrongly) have stopped at step 1."
    );
}
