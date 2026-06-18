//! Headless DAP column-aware test for the Flow/Cadence recorder pipeline.
//!
//! Spec:
//!   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M1.
//!
//! Companion to:
//!   * `dap_column_breakpoint.rs` — the canonical M1 acceptance test, which
//!     models a minified-JS bundle.
//!   * `cadence_flow_dap_test.rs` — the existing end-to-end Flow recorder
//!     test (variables only, `#[ignore]` because it requires the Go helper
//!     and the Cadence SDK on PATH).
//!
//! ## Why this test exists
//!
//! The Flow recorder's Go helper (`go-helper/main.go`) emits a `column`
//! field on every Cadence step, copied verbatim from `ast.Position.Column`
//! (see the helper's `convertCadencePos` and the call sites of
//! `register_step_with_column` on the Rust side).  The replay engine MUST
//! treat those columns the same way it treats columns from the JS / Python
//! recorders: as a first-class slot in the `(path, line, column)`
//! breakpoint key.
//!
//! End-to-end coverage already lives in `cadence_flow_dap_test.rs`, but
//! that test is `#[ignore]`d because it shells out to a Go toolchain.  The
//! present file pins the wire-level column-aware contract through the
//! production `Handler` without depending on the recorder being built — it
//! synthesises an in-memory materialised trace whose recorded path uses
//! the `.cdc` extension and whose `DbStep`s carry the columns the Cadence
//! AST would emit for a hand-crafted multi-statement Cadence line.
//!
//! ## Cadence multi-statement fixture
//!
//! Cadence permits multiple statements on one physical line when
//! separated by `;` (the Cadence grammar treats `;` as an explicit
//! statement terminator; the parser's `ast.Position.Column` is 1-based
//! and points at the first token of each statement).  Our hand-rolled
//! source line is:
//!
//!   line 1: `let a: Int = 10; let b: Int = 32; let c: Int = a + b;`
//!            ^               ^                ^
//!           col 1           col 18           col 35
//!
//!   line 5: `return c`  (a separate later statement at col 1)
//!
//! Steps the Go helper would surface for this line:
//!
//!   * step 0 — line 1, column 1   (`let a: Int = 10;`)
//!   * step 1 — line 1, column 18  (`let b: Int = 32;`)
//!   * step 2 — line 1, column 35  (`let c: Int = a + b;`)
//!   * step 3 — line 5, column 1   (legacy line-only target)
//!
//! ## Test matrix
//!
//! 1. `cadence_column_breakpoint_stops_at_recorded_column` — a
//!    `setBreakpoints` request with `{line: 1, column: 18}` MUST park the
//!    next `Continue` at step 1.  The DAP response MUST echo the bound
//!    column.
//!
//! 2. `cadence_line_only_breakpoint_still_stops_at_line_start` — back-
//!    compat: a `{line: 5}` request (no column) MUST land at step 3 and
//!    the response MUST NOT spuriously surface a column.
//!
//! 3. `cadence_column_breakpoint_skips_same_line_other_columns` — the
//!    anti-regression: a `{line: 1, column: 35}` request MUST skip the
//!    two earlier same-line steps and park at step 2.
//!
//! Compile/run:
//!   cd src/db-backend && cargo test --test dap_column_flow

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

/// Recorded path used by the synthetic Cadence trace.  Real Flow
/// recorder traces carry absolute `.cdc` paths; for the in-memory
/// fixture we use a path under the trace_dir so the M1 plumbing
/// resolves the source the same way it does for the JS fixture in
/// `dap_column_breakpoint.rs`.
const RECORDED_FILE: &str = "flow_column_test.cdc";

/// Columns the Cadence parser would assign to the three statements on
/// line 1 of `let a: Int = 10; let b: Int = 32; let c: Int = a + b;`.
/// `ast.Position.Column` is 1-based per the Cadence reference; the Go
/// helper converts to 1-based on the NDJSON boundary (see
/// `go-helper/main.go` line ~410).  Recomputed mentally to keep the
/// constants honest:
///
///   `let a: Int = 10;` ends at column 16, plus the space at column 17;
///   so the next `let b:` starts at column 18.  Similarly column 35 for
///   the third statement.
const COL_A: i64 = 1; // `let a: Int = 10;`
const COL_B: i64 = 18; // `let b: Int = 32;`
const COL_C: i64 = 35; // `let c: Int = a + b;`

/// A later, line-only statement (`return c`) used by the legacy
/// fallback sub-test.
const LATER_LINE: i64 = 5;

/// Build the in-memory materialised trace.  Mirrors the layout of the
/// canonical M1 fixture (`dap_column_breakpoint.rs::build_trace`) but
/// uses Cadence-flavoured paths/columns.
fn build_trace(trace_dir: &PathBuf) -> (Arc<dyn TraceReader>, String) {
    let recorded = trace_dir.join(RECORDED_FILE).display().to_string();
    let mut db = Db::new(trace_dir);

    // PathId(0) is the reserved sentinel slot used by the CTFS loader;
    // PathId(1) is the absolute recorded `.cdc` path.
    db.paths.push(String::new());
    db.paths.push(recorded.clone());
    db.path_map.insert(recorded.clone(), PathId(1));

    db.types.push(TypeRecord {
        kind: TypeKind::Int,
        lang_type: "Int".to_string(),
        specific_info: TypeSpecificInfo::None,
    });

    // `compute()` — the canonical Cadence function name used by the
    // existing `flow_test.cdc` fixture.  The exact name doesn't affect
    // the breakpoint logic but keeps the fixture honest as a Cadence
    // trace.
    db.functions.push(FunctionRecord {
        path_id: PathId(1),
        line: Line(1),
        name: "compute".to_string(),
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

    // Four steps matching the Cadence multi-statement fixture.
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

    // `step_map` is indexed by PathId then line; index 0 is the sentinel.
    db.step_map.push(HashMap::new());
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
    while rx.try_recv().is_ok() {}
    handler.step_id
}

/// Per-test trace directory.  Scoped to the pid + a unique tag so
/// concurrent `cargo test` runs don't stomp on one another's `Db`
/// state files.
fn make_trace_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("dap_column_flow_{}_{}", tag, std::process::id()));
    if !dir.exists() {
        std::fs::create_dir_all(&dir).expect("create trace dir");
    }
    dir
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// STRICT — a `setBreakpoints` request that carries `column: 18` on a
/// Cadence-recorded path MUST stop the next `Continue` at the step
/// recorded at column 18 — not at the earlier same-line steps at
/// columns 1 / 35.  This is the M1 column-aware contract applied to
/// the Flow/Cadence pipeline: the recorder emits `ast.Position.Column`
/// on every step, so the replay engine MUST honour it.
#[test]
fn cadence_column_breakpoint_stops_at_recorded_column() {
    let trace_dir = make_trace_dir("strict");
    let (reader, recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);

    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: 1,
            column: Some(COL_B),
            ..Default::default()
        }],
    );

    // Wire-level half of the M1 contract — DAP clients (VS Code, the
    // GUI, headless test rigs) all consume `Breakpoint.column` to
    // anchor the gutter marker.
    assert_eq!(body.breakpoints.len(), 1, "exactly one breakpoint in response");
    let bp = &body.breakpoints[0];
    assert!(bp.verified, "Cadence column breakpoint must verify; response: {bp:?}");
    assert_eq!(
        bp.column,
        Some(COL_B),
        "set_breakpoints response MUST echo the bound column ({COL_B} expected, got {:?})",
        bp.column
    );
    assert_eq!(bp.line, Some(1), "set_breakpoints response line must echo input");

    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(1),
        "Continue from step 0 with breakpoint at (line=1, col={COL_B}) MUST stop at step 1 \
         (the only step recorded at column {COL_B}); landed at {landed:?}"
    );
}

/// STRICT — a legacy line-only breakpoint MUST keep working through
/// the Cadence pipeline: Continue from step 0 with `{line: 5}` must
/// stop at the first step on line 5.  Back-compat half of the M1
/// contract — extending the breakpoint key with a column MUST NOT
/// break clients that send no column.
#[test]
fn cadence_line_only_breakpoint_still_stops_at_line_start() {
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
        StepId(3),
        "Continue from step 0 with line-only breakpoint at line {LATER_LINE} MUST stop at step 3 \
         (the only step recorded on that line); landed at {landed:?}"
    );
}

/// STRICT — a column-aware breakpoint MUST NOT match a step on the
/// same line at a different column.  Anti-regression for a
/// trivially-wrong implementation that stores the column without
/// consulting it on the stop check: setting `(line=1, col=35)` MUST
/// skip both earlier same-line steps (columns 1 and 18) and park at
/// step 2 — the only one at column 35.
#[test]
fn cadence_column_breakpoint_skips_same_line_other_columns() {
    let trace_dir = make_trace_dir("skip");
    let (reader, recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);

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
    assert!(bp.verified, "Cadence column breakpoint at COL_C must verify");
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
