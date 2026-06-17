//! M10 acceptance — column-aware DAP tracepoints (logpoints).
//!
//! Spec:
//!   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M10.
//!
//! A DAP **logpoint** is set via `setBreakpoints` with a non-empty
//! `logMessage`.  When execution passes through the matched
//! `(path, line, column)` the replay engine MUST:
//!
//!   1. Emit a single DAP `output` event carrying `logMessage` (no
//!      duplication across other columns on the same line).
//!   2. Continue WITHOUT stopping — no `stopped` event fires, no
//!      breakpoint hit is reported.
//!
//! Back-compat:
//!   * A legacy line-only logpoint (no `column`) fires on every
//!     recorded step on the line (the existing "stop on every
//!     statement on this line" semantics, but with no stop).
//!   * A column-aware logpoint MUST NOT fire when crossing other
//!     columns on the same line — the M1 anti-regression
//!     ("column-aware breakpoint skips same-line other columns")
//!     applies identically to the tracepoint surface.
//!
//! ## Fixture
//!
//! Same synthetic multi-statement-on-one-line JS recording used by
//! M1's `dap_column_breakpoint.rs`:
//!
//!   * step 0  — line 1, column 1   (`const a = 1;`)
//!   * step 1  — line 1, column 14  (`const b = 2;`)
//!   * step 2  — line 1, column 28  (`const c = a + b;`)
//!   * step 3  — line 5, column 1   (separate later statement)
//!
//! Compile/run:
//!   cd src/db-backend && cargo test --release --test dap_column_tracepoint

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

const RECORDED_FILE: &str = "bundle.min.js";

const COL_A: i64 = 1; // `const a = 1;`
const COL_B: i64 = 14; // `const b = 2;`
const COL_C: i64 = 28; // `const c = a + b;`

const LATER_LINE: i64 = 5;

fn build_trace(trace_dir: &PathBuf) -> (Arc<dyn TraceReader>, String) {
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

/// Drive a forward `Continue` through the Handler and return:
///   * the final `step_id`,
///   * every `output` event payload (the `output` field) emitted
///     during the Continue,
///   * a flag noting whether any `stopped` event was emitted.
///
/// The DAP `output` events are decoded out of the channel's
/// `DapMessage::Event` queue.  `stopped` events would arrive as a
/// distinct `DapMessage::Event` with `event == "stopped"` — we
/// flag any sighting because the M10 contract forbids them.
fn invoke_continue_forward(handler: &mut Handler) -> (StepId, Vec<String>, bool) {
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
    let mut output_messages: Vec<String> = Vec::new();
    let mut saw_stopped = false;
    while let Ok(msg) = rx.try_recv() {
        if let DapMessage::Event(ev) = msg {
            match ev.event.as_str() {
                "output" => {
                    let body: db_backend::dap_types::OutputEventBody =
                        serde_json::from_value(ev.body.clone()).expect("OutputEventBody decodes");
                    output_messages.push(body.output);
                }
                "stopped" => saw_stopped = true,
                _ => {}
            }
        }
    }
    (handler.step_id, output_messages, saw_stopped)
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// STRICT — a `setBreakpoints` request that carries
/// `{line: 1, column: 14, logMessage: "hit b"}` MUST cause exactly
/// ONE `output` event ("hit b") to fire on Continue, and MUST NOT
/// emit a `stopped` event (the column-aware logpoint is a pure
/// log-and-continue surface).  This is the M10 core requirement.
#[test]
fn column_tracepoint_emits_log_and_does_not_stop() {
    let trace_dir = std::env::temp_dir().join(format!("dap_column_tracepoint_test_{}", std::process::id()));
    if !trace_dir.exists() {
        std::fs::create_dir_all(&trace_dir).expect("create trace dir");
    }
    let (reader, recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);

    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: 1,
            column: Some(COL_B),
            log_message: Some("hit b".to_string()),
            ..Default::default()
        }],
    );

    assert_eq!(body.breakpoints.len(), 1, "exactly one tracepoint in response");
    let tp = &body.breakpoints[0];
    assert!(tp.verified, "tracepoint must be verified; response: {tp:?}");
    assert_eq!(
        tp.column,
        Some(COL_B),
        "setBreakpoints response MUST echo the bound column ({} expected, got {:?})",
        COL_B,
        tp.column
    );
    assert_eq!(tp.line, Some(1), "setBreakpoints response line must echo input");

    // ── Continue to end ───────────────────────────────────────────
    let (landed, outputs, saw_stopped) = invoke_continue_forward(&mut handler);

    // M10 — no breakpoint registered, so Continue runs to the last
    // step of the trace.  The handler MUST NOT have stopped early on
    // the matched tracepoint step.
    assert_eq!(
        landed,
        StepId(3),
        "Continue with only a tracepoint registered MUST reach end-of-trace; landed at {landed:?}"
    );

    // M10 — the `output` event for "hit b" MUST fire exactly once.
    let hits: Vec<&String> = outputs.iter().filter(|s| s.contains("hit b")).collect();
    assert_eq!(
        hits.len(),
        1,
        "expected exactly one 'hit b' output event; got {hits:?} (all outputs: {outputs:?})"
    );

    // M10 — no stopped event under any reason: a tracepoint logs but
    // doesn't stop.
    assert!(
        !saw_stopped,
        "tracepoint hit MUST NOT emit a `stopped` event; got one in: {outputs:?}"
    );
}

/// STRICT — a column-aware tracepoint MUST NOT fire when crossing
/// other columns on the same line.  Mirrors M1's
/// `column_breakpoint_skips_same_line_other_columns` anti-regression
/// — the M10 contract requires the same column-precision guarantee
/// at the logpoint surface.  Without this guard a trivially-wrong
/// implementation that fires on every step at the line would still
/// pass the basic "emits exactly one 'hit b'" test by luck whenever
/// the matched column happens to also be the first one on the line.
#[test]
fn column_tracepoint_skips_same_line_other_columns() {
    let trace_dir = std::env::temp_dir().join(format!("dap_column_tracepoint_skip_test_{}", std::process::id()));
    if !trace_dir.exists() {
        std::fs::create_dir_all(&trace_dir).expect("create trace dir");
    }
    let (reader, recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);

    // Tracepoint at the THIRD statement on line 1 (column 28).  A
    // line-only fallback would fire on every step on line 1
    // (columns 1, 14, 28) — producing 3 output events.  A correctly
    // column-aware engine MUST fire exactly once, on column 28.
    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: 1,
            column: Some(COL_C),
            log_message: Some("only-col-28".to_string()),
            ..Default::default()
        }],
    );
    assert_eq!(body.breakpoints.len(), 1);
    let tp = &body.breakpoints[0];
    assert!(tp.verified, "column tracepoint at COL_C must verify");
    assert_eq!(tp.column, Some(COL_C));

    let (_landed, outputs, saw_stopped) = invoke_continue_forward(&mut handler);
    assert!(!saw_stopped, "tracepoint MUST NOT emit a `stopped` event");
    let hits: Vec<&String> = outputs.iter().filter(|s| s.contains("only-col-28")).collect();
    assert_eq!(
        hits.len(),
        1,
        "expected exactly one 'only-col-28' output (recorded steps on line 1 at cols 1/14/28 — a \
         line-only fallback would have emitted 3); got {hits:?} (all outputs: {outputs:?})"
    );
}

/// STRICT — a legacy line-only tracepoint (no `column` on the
/// `SourceBreakpoint`) MUST keep firing on every recorded step on
/// the line.  The M10 contract preserves the legacy "line-only
/// logpoint" behaviour exactly as M1 preserved the line-only
/// breakpoint behaviour.  We assert THREE output events for the
/// three steps on line 1.
#[test]
fn line_only_tracepoint_fires_on_every_column_on_that_line() {
    let trace_dir = std::env::temp_dir().join(format!("dap_column_tracepoint_legacy_test_{}", std::process::id()));
    if !trace_dir.exists() {
        std::fs::create_dir_all(&trace_dir).expect("create trace dir");
    }
    let (reader, recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);

    let body = invoke_set_breakpoints(
        &mut handler,
        &recorded_path,
        vec![SourceBreakpoint {
            line: 1,
            column: None,
            log_message: Some("legacy".to_string()),
            ..Default::default()
        }],
    );
    assert_eq!(body.breakpoints.len(), 1);
    let tp = &body.breakpoints[0];
    assert!(tp.verified, "legacy line-only tracepoint must verify");
    assert_eq!(
        tp.column, None,
        "legacy line-only tracepoint MUST have column=None on the response"
    );

    let (_landed, outputs, saw_stopped) = invoke_continue_forward(&mut handler);
    assert!(!saw_stopped, "legacy tracepoint MUST NOT emit a `stopped` event");

    let hits: Vec<&String> = outputs.iter().filter(|s| s.contains("legacy")).collect();
    // The 3 steps on line 1 (cols 1, 14, 28) all match the legacy
    // line-only tracepoint; step 0 is the starting step and is
    // skipped by `step_continue` (it only iterates AFTER the current
    // step), so we expect exactly 2 hits (cols 14, 28).
    assert_eq!(
        hits.len(),
        2,
        "expected 2 'legacy' output events from steps 1 + 2 (cols 14, 28); \
         got {hits:?} (all outputs: {outputs:?})"
    );
}
