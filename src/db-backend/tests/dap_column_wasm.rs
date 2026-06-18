//! M-wasm — column-aware DAP breakpoints on a wazero/WASM-shaped trace.
//!
//! Spec: codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org
//! §M1 (WASM adaptation).  Companions:
//!   * `dap_column_breakpoint.rs` (canonical JS-shaped reference).
//!   * `dap_column_polkavm.rs` (PolkaVM sibling; same pattern, different
//!     fixture columns).
//!   * `codetracer-wasm-recorder/cmd/wazero/testdata/recorder-golden/
//!     column_aware.{rs,wasm}` (recorder-golden fixture; same source
//!     line that this test pins).
//!
//! What this test pins:
//!
//!   The wazero recorder (`codetracer-wasm-recorder`) compiles its
//!   regular-WASM steps from rustc-emitted DWARF.  `column_aware.rs`'s
//!   line 17 carries three statements
//!   (`let a: i32 = 1; let b: i32 = 2; let c: i32 = 3;`) and the rustc
//!   DWARF emitter pins those to columns 9, 25, 41 on line 17 — verified
//!   directly with `llvm-dwarfdump --debug-line column_aware.wasm`:
//!
//!     0x0000000000000074    17     9    1   0   0   0  is_stmt prologue_end
//!     0x000000000000007b    17    25    1   0   0   0
//!     0x0000000000000082    17    41    1   0   0   0
//!
//!   The DAP layer's column-aware match must honour those tuples
//!   end-to-end on a WASM-shaped trace.  This test stands the contract
//!   up against a synthetic in-memory trace that mirrors the
//!   recorder-golden DWARF columns exactly — no wazero/Go dependency in
//!   the cargo matrix.  The recorder-side regression lives in
//!   `codetracer-wasm-recorder/cmd/wazero/recorder_golden_test.go`; the
//!   ViewModel sister exercises a real recorder when one is available.
//!
//! Compile + run:
//!   cd src/db-backend && cargo test --test dap_column_wasm

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
// Mirrors `codetracer-wasm-recorder/cmd/wazero/testdata/recorder-golden/
// column_aware.{rs,wasm}` line 17 columns 9/25/41.  Confirmed by
// `llvm-dwarfdump --debug-line column_aware.wasm` (see module docstring).

/// The WASM blob the recorder runs.  Embedded as a breadcrumb on disk
/// alongside the source so anyone inspecting the trace dir sees both.
const RECORDED_BLOB: &str = "column_aware.wasm";
/// Source path the wazero recorder embeds into the trace's path table
/// (rustc DWARF carries the user-edited `.rs` path, not the blob path).
const SOURCE_FILE: &str = "column_aware.rs";

/// Multi-statement line in `column_aware.rs`
/// (`let a: i32 = 1; let b: i32 = 2; let c: i32 = 3;`).
const FIXTURE_LINE: i64 = 17;
/// `let a: i32 = 1;` — first statement starts at column 9.
const COL_LET_A: i64 = 9;
/// `let b: i32 = 2;` — second statement at column 25.
const COL_LET_B: i64 = 25;
/// `let c: i32 = 3;` — third statement at column 41.
const COL_LET_C: i64 = 41;
/// Later, line-only step — legacy-fallback target.  Mirrors the
/// `a + b + c` expression on the next source line (line 18) of the
/// recorder-golden fixture.
const RET_LINE: i64 = 18;

/// Build a synthetic in-memory `TraceReader` whose `DbStep`s replay the
/// recorder-golden column layout for `column_aware.wasm`.  Four steps:
///
///   * 0 → `let a` @ (17, 9)
///   * 1 → `let b` @ (17, 25)
///   * 2 → `let c` @ (17, 41)
///   * 3 → `a + b + c` @ (18, 1)   — legacy line-only target
fn build_trace(trace_dir: &PathBuf) -> (Arc<dyn TraceReader>, String) {
    // The wazero recorder rewrites step `path` entries to the rustc
    // DWARF file (the `.rs` source) — not the `.wasm` blob.  Mirror that
    // by registering the source path as PathId(1).
    let recorded = trace_dir.join(SOURCE_FILE).display().to_string();
    let mut db = Db::new(trace_dir);
    db.paths.push(String::new());
    db.paths.push(recorded.clone());
    db.path_map.insert(recorded.clone(), PathId(1));
    db.types.push(TypeRecord {
        kind: TypeKind::Int,
        lang_type: "i32".to_string(),
        specific_info: TypeSpecificInfo::None,
    });
    db.functions.push(FunctionRecord {
        path_id: PathId(1),
        line: Line(FIXTURE_LINE),
        name: "three_on_one_line".to_string(),
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
    let steps: [DbStep; 4] = [
        make_step(0, FIXTURE_LINE, COL_LET_A),
        make_step(1, FIXTURE_LINE, COL_LET_B),
        make_step(2, FIXTURE_LINE, COL_LET_C),
        make_step(3, RET_LINE, 1),
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
    path1_map.insert(FIXTURE_LINE as usize, vec![steps[0], steps[1], steps[2]]);
    path1_map.insert(RET_LINE as usize, vec![steps[3]]);
    db.step_map.push(path1_map);
    db.end_of_program = EndOfProgram::Normal;

    // Breadcrumb at the blob path documenting the "blob + source"
    // pairing the recorder repo emits.  Not consulted by the DAP layer.
    let _ = std::fs::write(trace_dir.join(RECORDED_BLOB), b"<synthetic wasm fixture>");

    let reader: Arc<dyn TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    (reader, recorded)
}

// ── Driver helpers ──────────────────────────────────────────────────────────

fn dap_request(seq: i64, command: &str) -> Request {
    Request {
        base: ProtocolMessage {
            seq,
            type_: "request".to_string(),
        },
        command: command.to_string(),
        arguments: serde_json::json!({}),
    }
}

fn invoke_set_breakpoints(
    handler: &mut Handler,
    path: &str,
    breakpoints: Vec<SourceBreakpoint>,
) -> SetBreakpointsResponseBody {
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let args = SetBreakpointsArguments {
        source: Source {
            path: Some(path.to_string()),
            ..Default::default()
        },
        breakpoints: Some(breakpoints),
        source_modified: None,
        lines: None,
    };
    handler
        .set_breakpoints(dap_request(1, "setBreakpoints"), args, tx)
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
    let arg = StepArg {
        action: Action::Continue,
        reverse: false,
        repeat: 0,
        complete: false,
        skip_internal: false,
        skip_no_source: false,
    };
    handler
        .step(dap_request(2, "continue"), arg, tx)
        .expect("continue succeeds");
    while rx.try_recv().is_ok() {}
    handler.step_id
}

fn fresh_trace_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("dap_column_wasm_{tag}_{}", std::process::id()));
    if !dir.exists() {
        std::fs::create_dir_all(&dir).expect("create trace dir");
    }
    dir
}

/// Boot a `Handler` over a fresh trace at step 0.  Returns
/// `(handler, recorded_path)` so callers can address the DAP source by
/// the same path the synthetic trace registered.
fn boot(tag: &str) -> (Handler, String) {
    let trace_dir = fresh_trace_dir(tag);
    let (reader, recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);
    (handler, recorded_path)
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// STRICT — `setBreakpoints {line: 17, column: 25}` stops the next
/// Continue at the step recorded at col 25 (the `let b` statement on
/// line 17 of the recorder-golden fixture), and the response echoes the
/// bound column back so DAP clients can anchor the gutter glyph.
#[test]
fn wasm_column_breakpoint_stops_at_recorded_column() {
    let (mut handler, recorded_path) = boot("hit");
    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: FIXTURE_LINE,
            column: Some(COL_LET_B),
            ..Default::default()
        }],
    );

    assert_eq!(body.breakpoints.len(), 1);
    let bp = &body.breakpoints[0];
    assert!(bp.verified, "breakpoint must verify: {bp:?}");
    assert_eq!(bp.column, Some(COL_LET_B), "response MUST echo bound column");
    assert_eq!(bp.line, Some(FIXTURE_LINE));

    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(1),
        "Continue from step 0 with bp at (line={FIXTURE_LINE}, col={COL_LET_B}) \
         MUST stop at step 1; landed {landed:?}"
    );
}

/// STRICT — a column-aware breakpoint at the THIRD column on the fixture
/// line MUST skip steps recorded at cols 9 and 25 and land at step 2.
/// Without this assertion an engine that stores the column but quietly
/// matches line-only would pass the first test by luck (step 1 happens
/// to be the second step on the line).
#[test]
fn wasm_column_breakpoint_skips_same_line_other_columns() {
    let (mut handler, recorded_path) = boot("skip");
    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: FIXTURE_LINE,
            column: Some(COL_LET_C),
            ..Default::default()
        }],
    );
    assert_eq!(body.breakpoints.len(), 1);
    let bp = &body.breakpoints[0];
    assert!(bp.verified, "bp at COL_LET_C must verify");
    assert_eq!(bp.column, Some(COL_LET_C));

    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(2),
        "Continue from step 0 with bp at (line={FIXTURE_LINE}, col={COL_LET_C}) MUST \
         stop at step 2; landed {landed:?}.  A line-only fallback would (wrongly) \
         have stopped at step 1."
    );
    // Document the unused first-column anchor so the full set of three
    // statement columns is visible at a glance.
    let _ = COL_LET_A;
}

/// STRICT — legacy line-only breakpoints (no column on the request)
/// MUST keep working on WASM traces.  Continue with `{line: 18}` stops
/// at step 3.  Pins the back-compat invariant for DAP clients that
/// pre-date the column-aware extension.
#[test]
fn wasm_line_only_breakpoint_still_stops_at_line_start() {
    let (mut handler, recorded_path) = boot("legacy");
    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: RET_LINE,
            column: None,
            ..Default::default()
        }],
    );
    assert_eq!(body.breakpoints.len(), 1);
    let bp = &body.breakpoints[0];
    assert!(bp.verified, "legacy line-only bp must verify");
    assert_eq!(bp.line, Some(RET_LINE));
    assert_eq!(bp.column, None, "legacy line-only bp MUST have column=None");

    let landed = invoke_continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(3),
        "Continue from step 0 with line-only bp at line {RET_LINE} MUST \
         stop at step 3; landed {landed:?}"
    );
}
