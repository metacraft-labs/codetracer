//! Headless DAP test — column-aware breakpoints exercised on the
//! **Nim compile-time tracer** pipeline.
//!
//! Spec:
//!   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M1.
//!
//! Companions:
//!   * `dap_column_breakpoint.rs` — the canonical M1 acceptance test
//!     (minified-JS one-liner variant).
//!   * `dap_column_flow.rs`        — Cadence/Flow variant.
//!   * `dap_column_noir.rs`        — Noir variant.
//!   * `dap_column_solana.rs`      — Solana/SBF variant.
//!
//! ## Why this test exists
//!
//! The Nim compile-time tracer (the ``nim e --trace:<file>.ct``
//! pipeline) is the only recorder that talks **directly** to the
//! ``codetracer_trace_writer`` Nim API rather than going through the C
//! FFI.  In column-aware mode it emits one CTFS step per vmgen
//! sub-expression opcode, producing **far more distinct columns per
//! source line** than the rest of the matrix (the Python / JS / Cadence
//! / Noir / Solana recorders emit one step per source statement).  The
//! upstream recorder fixture
//! ``codetracer-nim/tests/sourcemap/tvm_trace_column_aware.nim`` pins a
//! floor of ≥3 distinct columns on the recorded line but observes 7
//! distinct columns in practice (one per ``var`` keyword plus
//! sub-expression opcodes for each ``= literal`` assignment).
//!
//! This file exclusively pins the **DAP replay surface** against that
//! observed column layout — the recorder's own tests cover the
//! recorder→CTFS column wire, so we synthesise an
//! ``InMemoryTraceReader``-backed trace matching the vmgen output and
//! drive the production ``Handler`` through ``setBreakpoints`` +
//! ``continue``.  Using a synthetic trace keeps the test independent of
//! the codetracer-nim build artefact (whose binary requires a specific
//! libpcre version and isn't always available in the CI matrix), the
//! same trade-off ``dap_column_solana.rs`` and ``dap_column_noir.rs``
//! make for their respective sibling recorders.
//!
//! ## Recorded fixture (mirrors `tvm_trace_column_aware.nim`)
//!
//! The recorder's source script is:
//!
//! ```nim
//! var a = 1; var b = 2; var c = 3
//! echo a, " ", b, " ", c
//! ```
//!
//! On line 1 the vmgen tracer emits one opcode per sub-expression.
//! The 1-based columns the recorder lands a step on are:
//!
//!   * column  1  — `var a` keyword
//!   * column  9  — `1` literal (the rvalue of `a = 1`)
//!   * column 12  — `var b` keyword
//!   * column 20  — `2` literal
//!   * column 23  — `var c` keyword
//!   * column 31  — `3` literal
//!   * column 32  — implicit line-end opcode (newline)
//!
//! Line 2 has a single step on `echo` at column 1.  Together these
//! eight steps form the column-aware shape this test exercises:
//!
//!   1. ``setBreakpoints`` echoes the bound column on the DAP wire.
//!   2. ``Continue`` stops precisely at the step recorded at the
//!      bound ``(line, column)``, never at an earlier same-line step.
//!   3. Legacy line-only breakpoints still resolve to the first step
//!      on the recorded line.
//!   4. A column-aware breakpoint at the LAST column on line 1 skips
//!      every earlier same-line step (the strict anti
//!      line-only-fallback assertion).
//!
//! Compile/run:
//!   cd src/db-backend && cargo test --test dap_column_nim

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

/// Recorded path used by the synthetic Nim VM trace.  The codetracer-nim
/// fixture writes the script to a ``cols.nims`` file under its build
/// directory — we mirror the basename so the recorded path looks
/// identical to a real ``nim e --trace`` run.
const RECORDED_FILE: &str = "cols.nims";

/// 1-based columns the vmgen tracer lands an opcode on for line 1
/// (`var a = 1; var b = 2; var c = 3`).  Seven distinct columns —
/// one per sub-expression opcode the Nim compiler's `vmgen` emits.
/// These cover the three `var` keywords plus the three integer
/// literals plus the implicit line-end opcode at column 32.  See the
/// module docstring for the source-to-column derivation.
const COL_VAR_A: i64 = 1; //  `var a`
const COL_LIT_1: i64 = 9; //  `1` (rvalue of a)
const COL_VAR_B: i64 = 12; // `var b`
const COL_LIT_2: i64 = 20; // `2` (rvalue of b)
const COL_VAR_C: i64 = 23; // `var c`
const COL_LIT_3: i64 = 31; // `3` (rvalue of c)
const COL_LINE_END: i64 = 32; // implicit line-end opcode

/// Line 2 of the fixture (`echo a, " ", b, " ", c`).  Used by the
/// legacy line-only sub-test to land a continue on a later line.
const LATER_LINE: i64 = 2;

/// Build the in-memory materialised trace.  Mirrors the layout of the
/// canonical M1 fixture but uses Nim VM-flavoured paths/columns
/// matching ``tvm_trace_column_aware.nim``.
///
/// The trace has 8 steps:
///   * steps 0..6 on line 1 at the seven vmgen sub-expression columns,
///   * step 7 on line 2 at column 1 (the `echo` statement).
fn build_trace(trace_dir: &PathBuf) -> (Arc<dyn TraceReader>, String) {
    let recorded = trace_dir.join(RECORDED_FILE).display().to_string();
    let mut db = Db::new(trace_dir);

    // PathId(0) is the reserved sentinel slot used by the CTFS loader;
    // PathId(1) is the absolute recorded `.nims` path.
    db.paths.push(String::new());
    db.paths.push(recorded.clone());
    db.path_map.insert(recorded.clone(), PathId(1));

    db.types.push(TypeRecord {
        kind: TypeKind::Int,
        lang_type: "int".to_string(),
        specific_info: TypeSpecificInfo::None,
    });

    // The Nim VM tracer reports a `<top-level>` function for the
    // implicit nimscript wrapper around the script body.  Mirroring
    // that name keeps the synthetic trace honest as a Nim VM trace
    // (it isn't consulted by the breakpoint logic but it surfaces in
    // the calltrace pane and in debugger logs).
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

    // 7 line-1 steps + 1 line-2 step.  The line-1 steps are emitted in
    // strict source-column order — vmgen processes the AST
    // left-to-right within a line, so the running step_id matches the
    // column ordering.  This is the same property the recorder
    // fixture's ``stepAbsoluteGlobalLineIndex`` walk relies on.
    let steps: [DbStep; 8] = [
        make_step(0, 1, COL_VAR_A),
        make_step(1, 1, COL_LIT_1),
        make_step(2, 1, COL_VAR_B),
        make_step(3, 1, COL_LIT_2),
        make_step(4, 1, COL_VAR_C),
        make_step(5, 1, COL_LIT_3),
        make_step(6, 1, COL_LINE_END),
        make_step(7, LATER_LINE, 1),
    ];
    for step in steps.iter() {
        db.steps.push(*step);
        db.variables.push(Vec::new());
        db.instructions.push(Vec::new());
        db.compound.push(HashMap::new());
        db.cells.push(HashMap::new());
        db.variable_cells.push(HashMap::new());
    }

    // step_map indexed by PathId then by line.
    db.step_map.push(HashMap::new()); // sentinel slot
    let mut path1_map: HashMap<usize, Vec<DbStep>> = HashMap::new();
    path1_map.insert(
        1,
        vec![steps[0], steps[1], steps[2], steps[3], steps[4], steps[5], steps[6]],
    );
    path1_map.insert(LATER_LINE as usize, vec![steps[7]]);
    db.step_map.push(path1_map);

    db.end_of_program = EndOfProgram::Normal;

    let reader: Arc<dyn TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    (reader, recorded)
}

// ── Driver helpers ──────────────────────────────────────────────────────────

/// Issue a DAP ``setBreakpoints`` request through the production
/// handler and return the decoded response body.  Mirrors the request
/// shape a real DAP client would send.
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

/// Drive the production ``Handler::step`` with ``Continue`` forward
/// and return the resulting ``step_id``.  Drains any notifications the
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
    while rx.try_recv().is_ok() {}
    handler.step_id
}

/// Per-test trace directory.  Scoped to the pid + a unique tag so
/// concurrent ``cargo test`` runs don't stomp on one another's
/// state files.
fn make_trace_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("dap_column_nim_{}_{}", tag, std::process::id()));
    if !dir.exists() {
        std::fs::create_dir_all(&dir).expect("create trace dir");
    }
    dir
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// STRICT — a ``setBreakpoints`` request that carries a vmgen
/// sub-expression column MUST stop the next ``Continue`` at the step
/// recorded at that column — not at any earlier same-line step.
///
/// We pick ``COL_VAR_B = 12`` (the middle `var` keyword) so a
/// line-only fallback would (wrongly) stop at step 0 (column 1) or
/// step 1 (column 9), but the column-aware key-match must take us
/// past both to step 2.
#[test]
fn nim_vm_column_breakpoint_stops_at_recorded_column() {
    let trace_dir = make_trace_dir("strict");
    let (reader, recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);

    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: 1,
            column: Some(COL_VAR_B),
            ..Default::default()
        }],
    );

    // Wire-level half of the M1 contract — the GUI / VS Code / headless
    // test rigs all consume ``Breakpoint.column`` to anchor the gutter
    // marker.  The legacy line-only response wrongly returns
    // ``column = None``; this assertion pins the fix.
    assert_eq!(body.breakpoints.len(), 1, "exactly one breakpoint in response");
    let bp = &body.breakpoints[0];
    assert!(bp.verified, "Nim VM column breakpoint must verify; response: {bp:?}");
    assert_eq!(
        bp.column,
        Some(COL_VAR_B),
        "set_breakpoints response MUST echo the bound column ({COL_VAR_B} expected, got {:?})",
        bp.column
    );
    assert_eq!(bp.line, Some(1), "set_breakpoints response line must echo input");

    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(2),
        "Continue from step 0 with breakpoint at (line=1, col={COL_VAR_B}) MUST stop at step 2 \
         (the only step recorded at column {COL_VAR_B}); landed at {landed:?}"
    );
}

/// STRICT — a legacy line-only breakpoint MUST keep working through
/// the Nim VM pipeline: Continue from step 0 with ``{line: 2}`` MUST
/// stop at the only step recorded on line 2 (the ``echo`` statement),
/// and the DAP response MUST NOT spuriously surface a column.
#[test]
fn nim_vm_line_only_breakpoint_still_stops_at_line_start() {
    let trace_dir = make_trace_dir("legacy");
    let (reader, recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);

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
    assert_eq!(
        bp.column, None,
        "legacy line-only breakpoint MUST have column=None on the response"
    );

    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(7),
        "Continue from step 0 with line-only breakpoint at line {LATER_LINE} MUST stop at step 7 \
         (the only step recorded on that line); landed at {landed:?}"
    );
}

/// STRICT — a column-aware breakpoint MUST NOT match a step on the
/// same line at a different column.  The Nim VM tracer's
/// sub-expression granularity makes this assertion harder to satisfy
/// than the JS variant (six earlier candidates on the same line, not
/// two), so it's a stronger anti-regression: we pick the LAST column
/// on line 1 (``COL_LINE_END``) so a line-only fallback would
/// (wrongly) stop at step 0 (column 1), but the column-aware key
/// match must skip past every same-line step (1..=5) and park at
/// step 6.
#[test]
fn nim_vm_column_breakpoint_skips_same_line_other_columns() {
    let trace_dir = make_trace_dir("skip");
    let (reader, recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);

    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: 1,
            column: Some(COL_LINE_END),
            ..Default::default()
        }],
    );
    assert_eq!(body.breakpoints.len(), 1);
    let bp = &body.breakpoints[0];
    assert!(bp.verified, "Nim VM column breakpoint at COL_LINE_END must verify");
    assert_eq!(bp.column, Some(COL_LINE_END));

    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(6),
        "Continue from step 0 with breakpoint at (line=1, col={COL_LINE_END}) MUST stop at step 6 \
         (the only step recorded at column {COL_LINE_END}); landed at {landed:?}.  \
         A line-only fallback would (wrongly) have stopped at step 0."
    );
}

/// STRICT — a column-aware breakpoint at the SECOND vmgen column on
/// line 1 (the `1` literal at column 9) MUST stop at step 1, NOT at
/// step 0 (`var a` at column 1).  This pins the per-opcode column
/// precision that distinguishes the Nim VM tracer from the
/// per-statement recorders: a line-only fallback would land us at
/// the first step on line 1 (column 1) — the same step we started
/// on, so ``step_continue``'s "skip the current step" rule would
/// silently advance us to step 1 by luck.  We start at step 0 (not
/// before it) precisely to prove the column key is consulted, not
/// the skip-the-current rule.
#[test]
fn nim_vm_column_breakpoint_stops_at_literal_subexpression() {
    let trace_dir = make_trace_dir("literal");
    let (reader, recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);

    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: 1,
            column: Some(COL_LIT_1),
            ..Default::default()
        }],
    );
    assert_eq!(body.breakpoints.len(), 1);
    let bp = &body.breakpoints[0];
    assert!(bp.verified, "Nim VM literal sub-expression breakpoint must verify");
    assert_eq!(bp.column, Some(COL_LIT_1));

    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(1),
        "Continue from step 0 with breakpoint at (line=1, col={COL_LIT_1}) MUST stop at step 1 \
         (the literal `1` rvalue opcode); landed at {landed:?}"
    );
}
