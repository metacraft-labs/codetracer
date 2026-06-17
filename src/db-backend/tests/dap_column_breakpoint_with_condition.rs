//! M9 acceptance — column-aware breakpoints with an optional
//! `condition` expression.  Compose the M1 column-aware filter with
//! the conditional filter — "stop at column N only when expr holds".
//!
//! Spec:
//!   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M9.
//!
//! M1 added a column slot to `Breakpoint`; the Continue stop check
//! compared `DbStep.column` against the breakpoint's column.  M9
//! orthogonally adds a `condition: Option<String>` slot — when both
//! `column` and `condition` are `Some`, the stop check first filters
//! by column, then evaluates the condition against the locals
//! recorded at the candidate step, and only fires when both pass.
//!
//! ## What this test exercises
//!
//! We synthesise an in-memory materialised trace where one
//! minified-JS-style line (line 1) is hit multiple times across a
//! "loop" iteration: the same `(line, column)` tuple repeats with
//! different values of a local `i`.  Concretely:
//!
//!   * line 1, col 14 — `i = 50`   (step 0)
//!   * line 1, col 14 — `i = 100`  (step 1)  — boundary, should NOT fire
//!   * line 1, col 14 — `i = 150`  (step 2)  — first hit for `i > 100`
//!   * line 1, col 14 — `i = 200`  (step 3)
//!   * line 1, col 28 — `i = 200`  (step 4)  — different column, must skip
//!
//! Setting a column-aware breakpoint at `(line=1, col=14)` with
//! `condition: "i > 100"` MUST stop at step 2 — the first step where
//! the column matches AND the condition holds.
//!
//! ## Back-compat assertions
//!
//! - A line-only breakpoint with a condition still works (legacy
//!   conditional path).  M1 added column without breaking this; M9
//!   must not break it either.
//! - A column-only breakpoint with no condition behaves as M1 shipped
//!   (covered by the existing `dap_column_breakpoint.rs` test, not
//!   redundantly re-asserted here).
//!
//! Compile/run:
//!   cd src/db-backend && cargo test --release --test dap_column_breakpoint_with_condition

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc;

use codetracer_trace_types::{
    CallKey, FullValueRecord, FunctionId, FunctionRecord, Line, PathId, StepId, TypeId, TypeKind, TypeRecord,
    TypeSpecificInfo, ValueRecord, VariableId,
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

/// Recorded path used by the synthetic trace.  Mirrors the M1 fixture
/// (`bundle.min.js`) so the column-aware breakpoint plumbing is
/// exercised against the same path-id layout.
const RECORDED_FILE: &str = "bundle.min.js";

/// Column of the second statement on line 1 — the same column the M1
/// fixture pins (`var b = 2;`).
const COL_B: i64 = 14;

/// Column of the third statement on line 1 (`var c = a + b;`).  Used
/// to assert column-aware filtering: the conditional breakpoint at
/// COL_B MUST skip steps at COL_C even when their `i` satisfies the
/// condition.
const COL_C: i64 = 28;

/// Line of a separate "later" statement used by the back-compat
/// (line-only + condition) sub-test.
const LATER_LINE: i64 = 5;

/// Variable id assigned to the local `i` in the synthetic trace.
const VAR_I: VariableId = VariableId(1);

fn build_trace(trace_dir: &PathBuf) -> (Arc<dyn TraceReader>, String) {
    let recorded = trace_dir.join(RECORDED_FILE).display().to_string();
    let mut db = Db::new(trace_dir);

    // PathId(0) is the sentinel reserved by the CTFS loader.
    db.paths.push(String::new());
    db.paths.push(recorded.clone());
    db.path_map.insert(recorded.clone(), PathId(1));

    // The Int type — variable `i` resolves to this.
    db.types.push(TypeRecord {
        kind: TypeKind::Int,
        lang_type: "int".to_string(),
        specific_info: TypeSpecificInfo::None,
    });

    // Variable name table — index 0 reserved, index 1 = `i`.
    db.variable_names.push("<sentinel>".to_string());
    db.variable_names.push("i".to_string());

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

    // Seven steps:
    //   0 — line 1, col 14, i =  50
    //   1 — line 1, col 14, i = 100   (boundary: i > 100 is false)
    //   2 — line 1, col 14, i = 150   (first stop for `i > 100`)
    //   3 — line 1, col 14, i = 200
    //   4 — line 1, col 28, i = 200   (different column — must skip)
    //   5 — line 5, col 1,  i =  10   (line-only back-compat target)
    //   6 — line 9, col 1,  i =  10   (sentinel — last step in trace; the
    //                                  `step_continue` no-match fall-through
    //                                  parks here, so a successful match
    //                                  at step 5 is distinguishable from a
    //                                  no-match fall-through landing at the
    //                                  end of the trace).
    let plan: [(i64, i64, i64); 7] = [
        (1, COL_B, 50),
        (1, COL_B, 100),
        (1, COL_B, 150),
        (1, COL_B, 200),
        (1, COL_C, 200),
        (LATER_LINE, 1, 10),
        (9, 1, 10),
    ];
    let mut step_records: Vec<DbStep> = Vec::with_capacity(plan.len());
    for (idx, (line, col, i_value)) in plan.iter().enumerate() {
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
        db.variables.push(vec![FullValueRecord {
            variable_id: VAR_I,
            value: ValueRecord::Int {
                i: *i_value,
                type_id: TypeId(0),
            },
        }]);
        db.instructions.push(Vec::new());
        db.compound.push(HashMap::new());
        db.cells.push(HashMap::new());
        db.variable_cells.push(HashMap::new());
    }

    // step_map indexed by PathId then line.
    db.step_map.push(HashMap::new()); // sentinel for PathId(0)
    let mut path1_map: HashMap<usize, Vec<DbStep>> = HashMap::new();
    path1_map.insert(
        1,
        vec![
            step_records[0],
            step_records[1],
            step_records[2],
            step_records[3],
            step_records[4],
        ],
    );
    path1_map.insert(LATER_LINE as usize, vec![step_records[5]]);
    path1_map.insert(9usize, vec![step_records[6]]);
    db.step_map.push(path1_map);

    db.end_of_program = EndOfProgram::Normal;

    let reader: Arc<dyn TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    (reader, recorded)
}

// ── Driver helpers ──────────────────────────────────────────────────────────

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

fn make_handler(trace_dir_label: &str) -> (Handler, String) {
    let trace_dir = std::env::temp_dir().join(format!("dap_column_bp_cond_{}_{}", trace_dir_label, std::process::id()));
    if !trace_dir.exists() {
        std::fs::create_dir_all(&trace_dir).expect("create trace dir");
    }
    let (reader, recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);
    (handler, recorded_path)
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// STRICT — a `setBreakpoints` request that carries BOTH
/// `column: 14` AND `condition: "i > 100"` MUST stop the next Continue
/// at the first step where the column AND condition both hold.  This
/// is the M9 core requirement: the two filters compose orthogonally.
///
/// Steps 0 and 1 (i = 50, i = 100) are at the right column but fail
/// the condition.  Step 2 (i = 150) is the first hit.  Step 4 has
/// i = 200 but is on COL_C — the column filter MUST skip it even
/// though the condition would hold.
#[test]
fn column_breakpoint_with_condition_stops_at_first_satisfying_step() {
    let (mut handler, recorded_path) = make_handler("compose");

    // Set a column-aware breakpoint at col 14 with condition `i > 100`.
    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: 1,
            column: Some(COL_B),
            condition: Some("i > 100".to_string()),
            ..Default::default()
        }],
    );

    // DAP response must echo the column AND verify successfully.  The
    // condition isn't echoed back on the response body (DAP doesn't
    // define that round-trip slot), but the breakpoint MUST verify.
    assert_eq!(body.breakpoints.len(), 1, "exactly one breakpoint in response");
    let bp = &body.breakpoints[0];
    assert!(bp.verified, "M9 breakpoint must verify; response: {bp:?}");
    assert_eq!(
        bp.column,
        Some(COL_B),
        "DAP response must echo the bound column ({} expected, got {:?})",
        COL_B,
        bp.column
    );

    // Continue must stop at step 2 — the FIRST step with column 14
    // AND i > 100.
    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(2),
        "Continue from step 0 with breakpoint at (line=1, col={COL_B}) and `i > 100` MUST stop at \
         step 2 (the FIRST step where column == 14 AND i > 100). \
         Landed at {landed:?}.  A column-only fallback would (wrongly) have stopped at step 1 \
         (column matches, condition does not); a line-only fallback would have wrongly stopped \
         at step 0 (the very first step on line 1)."
    );
}

/// STRICT — back-compat for the legacy conditional path: a line-only
/// breakpoint (no column) with a condition MUST also be honoured.
///
/// We seed line 5 with a single step where `i = 10` and set a
/// breakpoint at `{line: 5, condition: "i > 100"}`.  Because the
/// condition does NOT hold at the only step on that line, the
/// Continue must run off the end of the trace (NOT stop spuriously).
///
/// We then re-seed the handler with a satisfying condition
/// (`condition: "i > 5"`) and verify Continue stops at step 5.
#[test]
fn line_only_breakpoint_with_condition_honours_expression() {
    // ── Variant A: condition fails — Continue must reach end ──────
    let (mut handler, recorded_path) = make_handler("legacy_fail");
    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: LATER_LINE,
            column: None,
            condition: Some("i > 100".to_string()),
            ..Default::default()
        }],
    );
    assert_eq!(body.breakpoints.len(), 1, "exactly one breakpoint in response");
    let bp = &body.breakpoints[0];
    assert!(bp.verified, "line-only conditional breakpoint must verify");
    assert_eq!(bp.line, Some(LATER_LINE));
    assert_eq!(
        bp.column, None,
        "line-only breakpoint MUST have column=None on the response"
    );

    let landed = invoke_continue_forward(&mut handler);
    // The fixture's last step is index 6 (sentinel at line 9).  A
    // no-match Continue falls through to the last step — so the
    // landing index disambiguates "fired at step 5" (StepId(5)) from
    // "ran off the end" (StepId(6)).  The unsatisfied condition must
    // produce the latter.
    assert_eq!(
        landed,
        StepId(6),
        "Continue with line-only breakpoint at line {LATER_LINE} but unsatisfied condition \
         `i > 100` MUST NOT stop at step 5 (where i = 10) — it must run off the end of the trace \
         to the sentinel last step (StepId(6)).  Landed at {landed:?}."
    );

    // ── Variant B: condition holds — Continue must stop ───────────
    let (mut handler, recorded_path) = make_handler("legacy_pass");
    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: LATER_LINE,
            column: None,
            condition: Some("i > 5".to_string()),
            ..Default::default()
        }],
    );
    assert_eq!(body.breakpoints.len(), 1);
    assert!(body.breakpoints[0].verified);

    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(5),
        "Continue with line-only breakpoint at line {LATER_LINE} and SATISFIED condition \
         `i > 5` (step 5 has i = 10) MUST stop at step 5.  Landed at {landed:?}."
    );
}

/// STRICT — composing column + condition where the condition NEVER
/// holds must NOT spuriously stop.  This guards against a buggy
/// implementation that silently ignores the condition when a column
/// is set (regressing to M1's unconditional column match).
///
/// Steps 0-3 all have column 14; step 4 has column 28.  Setting
/// `condition: "i > 1000"` (no step satisfies it) MUST run off the
/// end of the trace, not stop at any column-14 step.
#[test]
fn column_breakpoint_with_unsatisfiable_condition_runs_to_end() {
    let (mut handler, recorded_path) = make_handler("unsat");
    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: 1,
            column: Some(COL_B),
            condition: Some("i > 1000".to_string()),
            ..Default::default()
        }],
    );
    assert_eq!(body.breakpoints.len(), 1);
    assert!(body.breakpoints[0].verified);

    let landed = invoke_continue_forward(&mut handler);
    // The trace has 7 steps (indices 0..=6).  An unsatisfied
    // breakpoint causes step_continue to fall through to the end of
    // the trace, parking at the last step (StepId(6) — the sentinel
    // step on line 9).
    assert_eq!(
        landed,
        StepId(6),
        "Continue from step 0 with breakpoint at (line=1, col={COL_B}) and UNSATISFIABLE \
         condition `i > 1000` MUST run to the end of the trace (last step), NOT stop \
         at any column-14 step.  Landed at {landed:?}.  A buggy implementation that \
         silently ignores the condition would (wrongly) have stopped at step 1 (the \
         first column-14 step after step 0)."
    );
}
