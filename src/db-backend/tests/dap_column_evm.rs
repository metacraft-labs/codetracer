//! M-evm acceptance — column-aware breakpoints over an EVM/Solidity trace.
//!
//! Sister of ``dap_column_breakpoint.rs`` — same wire-level assertions,
//! but the synthetic in-memory trace uses Solidity source paths and
//! column tuples drawn from the canonical EVM fixture
//! (`codetracer-evm-recorder/test-programs/column_aware/ColumnAware.sol`).
//!
//! The reference Solidity source has the line
//!     `uint x = 1; uint y = 2; uint z = 3;`
//! indented 8 spaces, so the three statements start at columns
//! 9 / 21 / 33 (1-indexed).
//!
//! Why this test exists: the M1 column-aware breakpoint logic in
//! `dap_handler` is intentionally language-agnostic — it consults only
//! `DbStep.column` and matches the DAP `SourceBreakpoint.column` arg
//! against it.  This test pins that contract for the EVM/Solidity
//! pipeline so any future change that accidentally specialises a
//! surface to JS-only paths (e.g. gating column matching on file
//! extension or a JS-specific sourcemap) is caught immediately.
//!
//! Synthetic in-memory trace (mirroring `dap_column_breakpoint.rs`):
//! the DAP layer only cares about the materialised `(path, line,
//! column)` tuples on `DbStep`, so driving a real
//! `codetracer-evm-recorder` (with its `solc` / `anvil` deps) buys
//! nothing here — the ViewModel-level sister test exercises that path.
//!
//! Compile/run:
//!   cd src/db-backend && cargo test --test dap_column_evm

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

// ── Fixture (mirrors the EVM `ColumnAware.sol` canonical reference) ─────────

/// Recorded path used by the synthetic trace.  The trailing file
/// component is what DAP clients see in `Source.path`; the leading
/// directory only matters for path-equality during breakpoint resolution.
const RECORDED_FILE: &str = "ColumnAware.sol";

/// Line of the multi-statement body in the canonical fixture
/// (`uint x = 1; uint y = 2; uint z = 3;`).  Per
/// `codetracer-evm-recorder/test-programs/column_aware/ColumnAware.sol`
/// this lives on the third line of the `run()` body when the fixture is
/// counted from the contract's first line; in the synthetic trace the
/// concrete number is unimportant so long as the three column-distinct
/// steps land on the same line.
const MULTI_STMT_LINE: i64 = 19;

/// Columns of the three statements on `MULTI_STMT_LINE`, mirroring the
/// EVM recorder's 1-indexed column emission for the canonical fixture.
/// The Solidity body is indented 8 spaces; `uint x` opens at column 9,
/// `uint y` at column 21 and `uint z` at column 33.
const COL_X: i64 = 9; //  `uint x = 1;`
const COL_Y: i64 = 21; // `uint y = 2;`
const COL_Z: i64 = 33; // `uint z = 3;`

/// A later, line-only step that the legacy-fallback case lands on
/// (corresponds to `return x + y + z;` on the line below the multi-stmt
/// line in the canonical fixture).
const RETURN_LINE: i64 = 20;

fn build_trace(trace_dir: &PathBuf) -> (Arc<dyn TraceReader>, String) {
    let recorded = trace_dir.join(RECORDED_FILE).display().to_string();
    let mut db = Db::new(trace_dir);

    // PathId(0) is the reserved sentinel slot used by the canonical
    // CTFS loader; PathId(1) is the absolute recorded Solidity path.
    db.paths.push(String::new());
    db.paths.push(recorded.clone());
    db.path_map.insert(recorded.clone(), PathId(1));

    db.types.push(TypeRecord {
        kind: TypeKind::Int,
        lang_type: "uint256".to_string(),
        specific_info: TypeSpecificInfo::None,
    });

    db.functions.push(FunctionRecord {
        path_id: PathId(1),
        line: Line(MULTI_STMT_LINE),
        name: "ColumnAware.run".to_string(),
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

    // Four steps, mirroring what a column-aware EVM recorder must emit
    // for the canonical `ColumnAware.sol`:
    //
    //   0 — uint x = 1;   @ (MULTI_STMT_LINE, COL_X)
    //   1 — uint y = 2;   @ (MULTI_STMT_LINE, COL_Y)
    //   2 — uint z = 3;   @ (MULTI_STMT_LINE, COL_Z)
    //   3 — return x+y+z; @ (RETURN_LINE,     1)        legacy-fallback target
    let make_step = |id: i64, line: i64, col: i64| DbStep {
        step_id: StepId(id),
        path_id: PathId(1),
        line: Line(line),
        column: Some(Line(col)),
        call_key,
        global_call_key: call_key,
    };
    let steps: [DbStep; 4] = [
        make_step(0, MULTI_STMT_LINE, COL_X),
        make_step(1, MULTI_STMT_LINE, COL_Y),
        make_step(2, MULTI_STMT_LINE, COL_Z),
        make_step(3, RETURN_LINE, 1),
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
    path1_map.insert(RETURN_LINE as usize, vec![steps[3]]);
    db.step_map.push(path1_map);

    db.end_of_program = EndOfProgram::Normal;

    let reader: Arc<dyn TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    (reader, recorded)
}

// ── Driver helpers (identical pattern to dap_column_breakpoint.rs) ──────────

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

/// STRICT — a `setBreakpoints` request that carries `column: COL_Y` MUST
/// stop the next `Continue` at the step recorded at that column on the
/// multi-statement Solidity line — not at the earlier same-line step at
/// `COL_X` or the later one at `COL_Z`.  This is the M-evm contract:
/// the column-aware breakpoint key works end-to-end for EVM traces,
/// proving that the production code path is recorder-agnostic.
#[test]
fn column_breakpoint_stops_at_recorded_column_for_solidity_trace() {
    let trace_dir = std::env::temp_dir().join(format!("dap_column_evm_test_{}", std::process::id()));
    if !trace_dir.exists() {
        std::fs::create_dir_all(&trace_dir).expect("create trace dir");
    }
    let (reader, recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);

    // ── Set the column-aware breakpoint on the Solidity multi-stmt line.
    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: MULTI_STMT_LINE,
            column: Some(COL_Y),
            ..Default::default()
        }],
    );

    // STRICT — the DAP response MUST surface the bound column.  The
    // wire-level half of the M-evm contract: any DAP client (VS Code,
    // GUI, headless rig) that drives an EVM trace consumes
    // `Breakpoint.column` to anchor the gutter marker.
    assert_eq!(body.breakpoints.len(), 1, "exactly one breakpoint in response");
    let bp = &body.breakpoints[0];
    assert!(bp.verified, "breakpoint must be verified; response: {bp:?}");
    assert_eq!(
        bp.column,
        Some(COL_Y),
        "set_breakpoints response MUST echo the bound column ({} expected, got {:?})",
        COL_Y,
        bp.column
    );
    assert_eq!(
        bp.line,
        Some(MULTI_STMT_LINE),
        "set_breakpoints response line must echo input"
    );

    // ── Continue must stop precisely at (line=MULTI_STMT_LINE, col=COL_Y).
    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(1),
        "Continue from step 0 with breakpoint at \
         (line={MULTI_STMT_LINE}, col={COL_Y}) MUST stop at step 1 \
         (the only EVM step recorded at column {COL_Y}); landed at {landed:?}"
    );
}

/// STRICT — a legacy breakpoint with no column (existing line-only DAP
/// clients) MUST keep working: Continue from step 0 with breakpoint at
/// `{line: RETURN_LINE}` must stop at the first step on that line.
/// Back-compat half of the M-evm contract — extending the breakpoint
/// key does NOT break the existing line-only semantics for EVM traces.
#[test]
fn line_only_breakpoint_still_stops_at_line_start_for_solidity_trace() {
    let trace_dir = std::env::temp_dir().join(format!("dap_column_evm_legacy_test_{}", std::process::id()));
    if !trace_dir.exists() {
        std::fs::create_dir_all(&trace_dir).expect("create trace dir");
    }
    let (reader, recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);

    // Legacy DAP request — no column on the SourceBreakpoint.  This is
    // what a line-only DAP client (older VS Code, the pre-M1 CodeTracer
    // frontend) sends for an EVM-recorded trace.
    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: RETURN_LINE,
            column: None,
            ..Default::default()
        }],
    );
    assert_eq!(body.breakpoints.len(), 1, "exactly one breakpoint in response");
    let bp = &body.breakpoints[0];
    assert!(bp.verified, "legacy line-only breakpoint must verify");
    assert_eq!(bp.line, Some(RETURN_LINE));
    // A line-only breakpoint MUST NOT spuriously surface a column.
    assert_eq!(
        bp.column, None,
        "legacy line-only breakpoint MUST have column=None on the response"
    );

    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(3),
        "Continue from step 0 with line-only breakpoint at line {RETURN_LINE} MUST stop at step 3 \
         (the only step recorded on that line); landed at {landed:?}"
    );
}

/// STRICT — a column-aware breakpoint MUST NOT match a step on the same
/// Solidity line at a different column.  This guards against the
/// "weakened" interpretation where the engine quietly falls back to
/// line-only matching whenever a column is set for an EVM trace.
/// Without this test, a trivially-wrong implementation that stores the
/// column without consulting it on the stop check would pass the first
/// test (because step 1 happens to be the first step on
/// MULTI_STMT_LINE).  Here we target COL_Z (the third statement) — a
/// line-only fallback would wrongly stop at step 0 / step 1.
#[test]
fn column_breakpoint_skips_same_line_other_columns_for_solidity_trace() {
    let trace_dir = std::env::temp_dir().join(format!("dap_column_evm_skip_test_{}", std::process::id()));
    if !trace_dir.exists() {
        std::fs::create_dir_all(&trace_dir).expect("create trace dir");
    }
    let (reader, recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);

    // Breakpoint at (line=MULTI_STMT_LINE, col=COL_Z) — the *third*
    // statement.  A line-only fallback would wrongly stop at step 1
    // (the first step on this line after the current step 0).  A
    // correctly column-aware engine MUST skip steps 1 and land at
    // step 2 (the only step at COL_Z).
    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: MULTI_STMT_LINE,
            column: Some(COL_Z),
            ..Default::default()
        }],
    );
    assert_eq!(body.breakpoints.len(), 1);
    let bp = &body.breakpoints[0];
    assert!(bp.verified, "column breakpoint at COL_Z must verify");
    assert_eq!(bp.column, Some(COL_Z));

    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(2),
        "Continue from step 0 with breakpoint at (line={MULTI_STMT_LINE}, col={COL_Z}) MUST stop \
         at step 2 (the only step recorded at column {COL_Z}); landed at {landed:?}.  \
         A line-only fallback would (wrongly) have stopped at step 1."
    );
}
