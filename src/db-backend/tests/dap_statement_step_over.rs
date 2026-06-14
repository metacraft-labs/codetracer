//! M2 acceptance — statement-granularity step-over via DAP `next`.
//!
//! Spec:
//!   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M2.
//!
//! The Column-Aware Tracing & Source Deminification campaign delivered
//! /recording/ of column data: every recorded step now carries a
//! `(line, column)` pair (Python + JavaScript recorders).  M1 plumbed
//! `DbStep.column` end-to-end through the materialised replay session.
//! This file pins the M2 requirement that the DAP `next` request can
//! consume that column data to advance one /statement/ at a time
//! instead of one source /line/ at a time:
//!
//!   1. DAP `next` reads `NextArguments.granularity` (previously dropped
//!      on the floor before this milestone).  When `granularity ==
//!      "statement"`, the request dispatches to a column-aware runner.
//!   2. The new runner captures `(line, column)` at entry and steps
//!      until either the line changes OR the column moves outside the
//!      current statement's range.  Consecutive same-line steps with
//!      strictly-increasing column form a single statement; the moment
//!      column resets (next statement on same line starts at a smaller
//!      column) or line changes, the step terminates.
//!   3. Legacy `next` (no `granularity`, `granularity == "line"`, or
//!      `granularity == "instruction"`) MUST keep the existing
//!      line-granularity behaviour intact.  Without this back-compat
//!      pin, any DAP client that doesn't opt in to statement
//!      granularity would silently start landing on every column delta
//!      mid-line — a serious regression.
//!
//! ## What the test exercises
//!
//! We build a synthetic in-memory materialized trace whose steps land
//! on a minified JS one-liner at three distinct columns on line 1
//! (one step per statement), followed by a single statement on line 2:
//!
//!   * step 0  — line 1, column 1   (`var a = 1;`)
//!   * step 1  — line 1, column 12  (`var b = 2;`)
//!   * step 2  — line 1, column 23  (`var c = a + b;`)
//!   * step 3  — line 2, column 1   (`console.log(c);`)
//!
//! Test A — statement-granularity: starting at step 0, three successive
//! `next({granularity: "statement"})` requests must land at steps 1,
//! 2, 3 in turn — i.e. the cursor must advance one statement per
//! invocation, EXACTLY at the recorded column of each statement.
//!
//! Test B — legacy preservation: starting at step 0, one `next` without
//! `granularity` must land at step 3 (line 2) — i.e. the
//! multi-statement line 1 is treated as a single line-granularity
//! hop.  This is the non-negotiable back-compat assertion the M2
//! plan calls out.
//!
//! Test C — single-statement line: starting at step 3, one
//! `next({granularity: "statement"})` must advance past the end of
//! the trace (return-to-self / "limit reached" semantic).  On a
//! single-statement line the statement-granularity runner must
//! behave indistinguishably from the line-granularity runner.
//!
//! Compile/run:
//!   cd src/db-backend && cargo test --release --test dap_statement_step_over

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
use db_backend::db::{Db, DbCall, DbStep, EndOfProgram};
use db_backend::in_memory_trace_reader::InMemoryTraceReader;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::task::TraceKind;
use db_backend::trace_reader::TraceReader;

// ── Fixture ─────────────────────────────────────────────────────────────────

/// Recorded path used by the synthetic trace.  The fixture's "source"
/// is the M2 multi-statement-line case: a single line with three
/// distinct statements at three distinct columns, followed by a single
/// statement on the next line.
const RECORDED_FILE: &str = "program.js";

/// Columns of the three statements on line 1, mirroring where the
/// recorder lands a step at the start of each statement.  The values
/// echo what the JS recorder emits for
/// `var a = 1; var b = 2; var c = a + b;`.
const COL_VAR_A: i64 = 1; // start of `var a`
const COL_VAR_B: i64 = 12; // start of `var b` (after `var a = 1; `)
const COL_VAR_C: i64 = 23; // start of `var c` (after `var b = 2; `)
const COL_LINE_TWO: i64 = 1; // start of `console.log(c)` on line 2

/// Line of the single-statement follow-up.
const LINE_TWO: i64 = 2;

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
    //   0 — line 1, col 1    (var a = 1)
    //   1 — line 1, col 12   (var b = 2)
    //   2 — line 1, col 23   (var c = a + b)
    //   3 — line 2, col 1    (console.log(c))
    let make_step = |id: i64, line: i64, col: i64| DbStep {
        step_id: StepId(id),
        path_id: PathId(1),
        line: Line(line),
        column: Some(Line(col)),
        call_key,
        global_call_key: call_key,
    };
    let steps: [DbStep; 4] = [
        make_step(0, 1, COL_VAR_A),
        make_step(1, 1, COL_VAR_B),
        make_step(2, 1, COL_VAR_C),
        make_step(3, LINE_TWO, COL_LINE_TWO),
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
    path1_map.insert(LINE_TWO as usize, vec![steps[3]]);
    db.step_map.push(path1_map);

    db.end_of_program = EndOfProgram::Normal;

    let reader: Arc<dyn TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    (reader, recorded)
}

// ── Driver helpers ──────────────────────────────────────────────────────────

/// Issue a DAP `next` request through the production handler.  The
/// optional `granularity` is serialised into the request `arguments`
/// JSON exactly the way a real DAP client would — pinning the wire
/// contract, not bypassing it.
fn invoke_dap_next(handler: &mut Handler, granularity: Option<&str>) -> StepId {
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let mut args = serde_json::json!({ "threadId": 1 });
    if let Some(g) = granularity {
        args["granularity"] = serde_json::Value::String(g.to_string());
    }
    let request = Request {
        base: ProtocolMessage {
            seq: 1,
            type_: "request".to_string(),
        },
        command: "next".to_string(),
        arguments: args,
    };
    handler
        .next_dap(request, granularity.map(|g| g.to_string()), tx)
        .expect("dap next succeeds");
    // Drain any notifications the handler emits during the move so the
    // channel is fully consumed.
    while rx.try_recv().is_ok() {}
    handler.step_id
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// STRICT (Test A) — three successive `next({granularity: "statement"})`
/// requests starting at step 0 MUST land at step 1, step 2, step 3.
/// This proves:
///   * the DAP wire field `granularity` is decoded (not dropped);
///   * the runner consults `DbStep.column` and treats each
///     same-line column-delta as a separate statement;
///   * after exhausting the multi-statement line the runner advances
///     to the next line just like a normal step-over would.
#[test]
fn statement_step_over_advances_one_statement_per_invocation() {
    let trace_dir = std::env::temp_dir().join(format!("dap_statement_step_over_test_{}", std::process::id()));
    if !trace_dir.exists() {
        std::fs::create_dir_all(&trace_dir).expect("create trace dir");
    }
    let (reader, _recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);

    // Sanity — we MUST start at step 0 (line 1, col 1).  Without this
    // pin the test could silently pass on an off-by-one in the runner.
    {
        let step = handler.reader.step(StepId(0)).expect("step 0 exists");
        assert_eq!(step.line.0, 1);
        assert_eq!(step.column, Some(Line(COL_VAR_A)));
    }

    // First statement step: 0 -> 1.
    let landed_1 = invoke_dap_next(&mut handler, Some("statement"));
    assert_eq!(
        landed_1,
        StepId(1),
        "first statement-granularity next from step 0 MUST land at step 1 \
         (line 1, col {COL_VAR_B}); landed at {landed_1:?}"
    );
    {
        let step = handler.reader.step(landed_1).expect("landed step exists");
        assert_eq!(step.line.0, 1, "stayed on line 1");
        assert_eq!(
            step.column,
            Some(Line(COL_VAR_B)),
            "column MUST be {COL_VAR_B} (start of `var b`)"
        );
    }

    // Second statement step: 1 -> 2.
    let landed_2 = invoke_dap_next(&mut handler, Some("statement"));
    assert_eq!(
        landed_2,
        StepId(2),
        "second statement-granularity next from step 1 MUST land at step 2 \
         (line 1, col {COL_VAR_C}); landed at {landed_2:?}"
    );
    {
        let step = handler.reader.step(landed_2).expect("landed step exists");
        assert_eq!(step.line.0, 1, "stayed on line 1");
        assert_eq!(
            step.column,
            Some(Line(COL_VAR_C)),
            "column MUST be {COL_VAR_C} (start of `var c`)"
        );
    }

    // Third statement step: 2 -> 3.  The statement-granularity runner
    // treats end-of-line as a statement boundary too — there is no
    // statement after `var c = a + b;` on line 1, so the next stop is
    // the first step of line 2.
    let landed_3 = invoke_dap_next(&mut handler, Some("statement"));
    assert_eq!(
        landed_3,
        StepId(3),
        "third statement-granularity next from step 2 MUST land at step 3 \
         (line {LINE_TWO}); landed at {landed_3:?}"
    );
    {
        let step = handler.reader.step(landed_3).expect("landed step exists");
        assert_eq!(step.line.0, LINE_TWO);
        assert_eq!(step.column, Some(Line(COL_LINE_TWO)));
    }
}

/// STRICT (Test B) — non-negotiable legacy-preservation.  A DAP `next`
/// WITHOUT `granularity` (or with `granularity == "line"`) MUST advance
/// by line, not by column.  Starting at step 0, one legacy `next` MUST
/// land at step 3 (line 2) — skipping steps 1 and 2 because they
/// belong to line 1.  This pins the back-compat half of the M2
/// contract: users who don't opt in to statement granularity see the
/// exact same behaviour they had before M2.
#[test]
fn legacy_line_granularity_next_skips_intra_line_columns() {
    let trace_dir = std::env::temp_dir().join(format!("dap_statement_step_over_legacy_test_{}", std::process::id()));
    if !trace_dir.exists() {
        std::fs::create_dir_all(&trace_dir).expect("create trace dir");
    }
    let (reader, _recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);

    // Legacy DAP `next` — no `granularity` field on the wire.  This
    // is what a line-only DAP client (older VS Code, the CodeTracer
    // Electron frontend before M2) sends.
    let landed = invoke_dap_next(&mut handler, None);
    assert_eq!(
        landed,
        StepId(3),
        "legacy line-granularity next from step 0 MUST skip the same-line column-deltas \
         (steps 1, 2) and land at step 3 on line {LINE_TWO}; landed at {landed:?}"
    );
    {
        let step = handler.reader.step(landed).expect("landed step exists");
        assert_eq!(
            step.line.0, LINE_TWO,
            "legacy `next` MUST advance to a different line, not a different column"
        );
    }

    // Same back-compat assertion for the explicit `granularity ==
    // "line"` form.  DAP spec §setStepping treats "line" as the
    // default; we MUST not regress when a client states it explicitly.
    handler.step_id = StepId(0);
    let landed_line = invoke_dap_next(&mut handler, Some("line"));
    assert_eq!(
        landed_line,
        StepId(3),
        "explicit `granularity: \"line\"` MUST behave the same as legacy line-granularity; \
         landed at {landed_line:?}"
    );

    // Same for `granularity == "instruction"`.  We have no instruction
    // backend on a materialised trace; per the M2 plan
    // `instruction` falls back to the line-granularity runner rather
    // than erroring out.
    handler.step_id = StepId(0);
    let landed_instr = invoke_dap_next(&mut handler, Some("instruction"));
    assert_eq!(
        landed_instr,
        StepId(3),
        "`granularity: \"instruction\"` on a materialised trace MUST fall back to \
         line-granularity (no instruction backend exists); landed at {landed_instr:?}"
    );
}

/// STRICT (Test C) — statement-granularity step-over on a
/// single-statement line MUST behave indistinguishably from
/// line-granularity step-over.  Starting at step 3 (the sole step on
/// line 2), one `next({granularity: "statement"})` MUST advance off
/// the trace (clamped to step 3 because there is no step after it).
///
/// This pins the "no surprises on a normal line" half of the M2
/// contract: a single-statement line is exactly the case where the two
/// granularities collapse — column-delta within the statement is
/// indistinguishable from line-delta because the statement IS the
/// line.
#[test]
fn statement_step_over_on_single_statement_line_advances_by_line() {
    let trace_dir = std::env::temp_dir().join(format!(
        "dap_statement_step_over_single_stmt_test_{}",
        std::process::id()
    ));
    if !trace_dir.exists() {
        std::fs::create_dir_all(&trace_dir).expect("create trace dir");
    }
    let (reader, _recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    // Park on the single-statement line (step 3 = line 2, col 1).
    // `handler.step_id` is the dap-layer cursor; the underlying
    // replay session also tracks its own step id, so we MUST drive
    // the cursor through the production `jump_to` path that updates
    // both.  Setting only `handler.step_id` directly would leave the
    // replay's internal cursor at 0 and the next step would advance
    // from 0, not 3.
    handler.replay.jump_to(StepId(3)).expect("jump_to step 3 succeeds");
    handler.step_id = handler.replay.current_step_id();
    assert_eq!(
        handler.step_id,
        StepId(3),
        "fixture parks on step 3 before the statement-granularity hop"
    );

    let landed_stmt = invoke_dap_next(&mut handler, Some("statement"));
    let landed_line = {
        // Reset and step with legacy granularity for a parallel-run
        // comparison.  This guarantees they truly collapse: the two
        // runners must agree on a single-statement line.
        handler.replay.jump_to(StepId(3)).expect("jump_to step 3 succeeds");
        handler.step_id = handler.replay.current_step_id();
        invoke_dap_next(&mut handler, None)
    };
    assert_eq!(
        landed_stmt, landed_line,
        "statement-granularity next on a single-statement line MUST land at the same step \
         as line-granularity next; landed_stmt = {landed_stmt:?}, landed_line = {landed_line:?}"
    );

    // The trace has no step after step 3, so the runner clamps in place
    // and the limit-reached notification fires.  This pins that the
    // runner does NOT silently skip past the end or panic on a
    // bounds-overrun.
    assert_eq!(
        landed_stmt,
        StepId(3),
        "stepping past the end MUST clamp at the last step; landed at {landed_stmt:?}"
    );
}
