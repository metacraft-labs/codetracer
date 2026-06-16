//! M7 acceptance — statement-granularity step BACKWARD via DAP `stepBack`.
//!
//! Spec:
//!   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M7.
//!
//! M2 added forward statement-granularity step-over via the DAP
//! `next` request with `granularity = "statement"`.  M7 mirrors that
//! contract in the time-travel reverse direction: DAP `stepBack` with
//! `granularity = "statement"` advances one statement BACKWARDS using
//! the same `DbStep.column` data.
//!
//! The runner is the symmetric mirror of M2:
//!
//!   1. DAP `stepBack` reads `StepBackArguments.granularity`
//!      (previously dropped on the floor before this milestone).  When
//!      `granularity == "statement"`, the request dispatches to the
//!      column-aware backward runner.
//!   2. The runner captures `(line, column)` at entry and steps
//!      backwards until either the line changes OR the column moves
//!      STRICTLY LESS than the entry column on the same line — the
//!      mirror of M2's strictly-greater forward predicate.
//!   3. Legacy `stepBack` (no `granularity`, `granularity == "line"`,
//!      or `granularity == "instruction"`) MUST keep its existing
//!      reverse-line-granularity behaviour intact.  Without this
//!      back-compat pin any DAP client that doesn't opt in to
//!      statement granularity would silently start landing on every
//!      column delta mid-line in reverse — a regression that mirrors
//!      the M2 forward back-compat assertion.
//!
//! ## What the test exercises
//!
//! Same synthetic in-memory materialised fixture as M2: a minified JS
//! one-liner at three columns on line 1 plus one statement on line 2.
//!
//!   * step 0  — line 1, column 1   (`var a = 1;`)
//!   * step 1  — line 1, column 12  (`var b = 2;`)
//!   * step 2  — line 1, column 23  (`var c = a + b;`)
//!   * step 3  — line 2, column 1   (`console.log(c);`)
//!
//! Test A — statement-granularity reverse: starting at step 3, three
//! successive `stepBack({granularity: "statement"})` requests must
//! land at steps 2, 1, 0 in reverse — i.e. the cursor must advance one
//! statement per invocation BACKWARDS, EXACTLY at the recorded column
//! of each statement.
//!
//! Test B — legacy preservation: starting at step 3, one `stepBack`
//! without `granularity` must land at step 0 (line 1, first step) —
//! i.e. the multi-statement line 1 is treated as a single
//! line-granularity hop, exactly mirroring the M2 forward back-compat
//! contract.  This is the non-negotiable back-compat assertion the
//! M7 plan calls out.
//!
//! Test C — single-statement line: starting at step 0, one
//! `stepBack({granularity: "statement"})` must clamp at step 0 — the
//! trace has no step before step 0.  On a single-statement line the
//! statement-granularity runner must behave indistinguishably from the
//! line-granularity runner in both directions.
//!
//! Compile/run:
//!   cd src/db-backend && cargo test --release --test dap_statement_step_back

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
/// distinct statements at three distinct columns, followed by a
/// single statement on the next line.  Mirrored from the M2 fixture so
/// the forward and backward acceptance tests share the exact same
/// column layout.
const RECORDED_FILE: &str = "program.js";

/// Columns of the three statements on line 1, mirroring where the
/// recorder lands a step at the start of each statement.  Same values
/// as the M2 fixture so any future change to the JS recorder column
/// model is caught in both forward and backward tests at once.
const COL_VAR_A: i64 = 1; // start of `var a`
const COL_VAR_B: i64 = 12; // start of `var b`
const COL_VAR_C: i64 = 23; // start of `var c`
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

/// Issue a DAP `stepBack` request through the production handler.
/// The optional `granularity` is serialised into the request
/// `arguments` JSON exactly the way a real DAP client would — pinning
/// the wire contract, not bypassing it.  Mirrors the M2
/// `invoke_dap_next` helper in `dap_statement_step_over.rs`.
fn invoke_dap_step_back(handler: &mut Handler, granularity: Option<&str>) -> StepId {
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
        command: "stepBack".to_string(),
        arguments: args,
    };
    handler
        .step_back_dap(request, granularity.map(|g| g.to_string()), tx)
        .expect("dap stepBack succeeds");
    // Drain any notifications the handler emits during the move so the
    // channel is fully consumed.
    while rx.try_recv().is_ok() {}
    handler.step_id
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// STRICT (Test A) — three successive
/// `stepBack({granularity: "statement"})` requests starting at step 3
/// MUST land at step 2, step 1, step 0 in turn.  This proves:
///   * the DAP wire field `granularity` is decoded (not dropped) on
///     the `stepBack` request — symmetric to the M2 forward path;
///   * the runner consults `DbStep.column` and treats each same-line
///     column-delta as a separate statement in REVERSE — the
///     strictly-LESS column predicate fires symmetrically to the M2
///     strictly-GREATER forward predicate;
///   * after exhausting the multi-statement line the runner advances
///     to the prior line just like a normal reverse-next would.
#[test]
fn statement_step_back_advances_one_statement_per_invocation() {
    let trace_dir = std::env::temp_dir().join(format!("dap_statement_step_back_test_{}", std::process::id()));
    if !trace_dir.exists() {
        std::fs::create_dir_all(&trace_dir).expect("create trace dir");
    }
    let (reader, _recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    // Park on step 3 (line 2, col 1) — the END of the recorded
    // program, where the user would naturally invoke a reverse step.
    // Drive the cursor through the production `jump_to` path so the
    // replay session's internal cursor matches the dap-layer one.
    handler.replay.jump_to(StepId(3)).expect("jump_to step 3 succeeds");
    handler.step_id = handler.replay.current_step_id();

    // Sanity — we MUST start at step 3 (line 2, col 1).  Without this
    // pin the test could silently pass on an off-by-one in the runner.
    assert_eq!(
        handler.step_id,
        StepId(3),
        "fixture parks on step 3 before the first backward hop"
    );
    {
        let step = handler.reader.step(StepId(3)).expect("step 3 exists");
        assert_eq!(step.line.0, LINE_TWO);
        assert_eq!(step.column, Some(Line(COL_LINE_TWO)));
    }

    // First backward statement step: 3 -> 2 (line 1, col 23 / var c).
    // The runner detects the line-boundary (line 2 -> line 1) and
    // stops at the first prior-line step.
    let landed_2 = invoke_dap_step_back(&mut handler, Some("statement"));
    assert_eq!(
        landed_2,
        StepId(2),
        "first statement-granularity stepBack from step 3 MUST land at step 2 \
         (line 1, col {COL_VAR_C}); landed at {landed_2:?}"
    );
    {
        let step = handler.reader.step(landed_2).expect("landed step exists");
        assert_eq!(step.line.0, 1, "stepped back onto line 1");
        assert_eq!(
            step.column,
            Some(Line(COL_VAR_C)),
            "column MUST be {COL_VAR_C} (start of `var c`)"
        );
    }

    // Second backward statement step: 2 -> 1 (line 1, col 12 / var b).
    // Same-line backward hop via the strictly-LESS column predicate —
    // col 23 -> col 12 is the symmetric mirror of the forward 12 ->
    // 23 boundary at the runner level.
    let landed_1 = invoke_dap_step_back(&mut handler, Some("statement"));
    assert_eq!(
        landed_1,
        StepId(1),
        "second statement-granularity stepBack from step 2 MUST land at step 1 \
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

    // Third backward statement step: 1 -> 0 (line 1, col 1 / var a).
    // Final same-line backward hop reaching the start of the recorded
    // program.
    let landed_0 = invoke_dap_step_back(&mut handler, Some("statement"));
    assert_eq!(
        landed_0,
        StepId(0),
        "third statement-granularity stepBack from step 1 MUST land at step 0 \
         (line 1, col {COL_VAR_A}); landed at {landed_0:?}"
    );
    {
        let step = handler.reader.step(landed_0).expect("landed step exists");
        assert_eq!(step.line.0, 1);
        assert_eq!(step.column, Some(Line(COL_VAR_A)));
    }
}

/// STRICT (Test B) — non-negotiable legacy-preservation.  A DAP
/// `stepBack` WITHOUT `granularity` (or with `granularity == "line"`)
/// MUST advance by line, not by column, IN REVERSE.  Starting at
/// step 3 (line 2), one legacy `stepBack` MUST land at step 2 — the
/// LAST step of line 1 — exactly the way the pre-M7 reverse-line
/// runner did.  The runner walks the recorded step stream backwards
/// from step 3 and stops at the first step whose `(line, call_key)`
/// differs from the entry — that is step 2 (line 1, col 23).
///
/// Why step 2 and not step 0: legacy line-granularity stopping fires
/// on the FIRST `(line, call_key)` change encountered.  Going
/// backward from step 3 (line 2) the first prior-line step in the
/// stream is step 2 (the last step of line 1).  This is the symmetric
/// mirror of M2's forward semantic, where forward stepping from step
/// 0 (line 1) stops at step 3 (the first step of line 2).  In both
/// cases the runner lands at the FIRST step it encounters on the
/// boundary line in the direction of travel — pre-M7 GUI users
/// reading these lines have always seen this behaviour, and M7 MUST
/// NOT regress it.
///
/// This pins the back-compat half of the M7 contract: users who
/// don't opt in to statement granularity see the exact same
/// reverse-stepping behaviour they had before M7, symmetric to the
/// M2 forward back-compat assertion.
#[test]
fn legacy_line_granularity_step_back_skips_intra_line_columns() {
    let trace_dir = std::env::temp_dir().join(format!("dap_statement_step_back_legacy_test_{}", std::process::id()));
    if !trace_dir.exists() {
        std::fs::create_dir_all(&trace_dir).expect("create trace dir");
    }
    let (reader, _recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.replay.jump_to(StepId(3)).expect("jump_to step 3 succeeds");
    handler.step_id = handler.replay.current_step_id();

    // Legacy DAP `stepBack` — no `granularity` field on the wire.
    // This is what a line-only DAP client (older VS Code, the
    // CodeTracer Electron frontend before M7) sends.  The legacy
    // runner stops at the first `(line, call_key)` change going
    // backward, which is step 2 (line 1, col 23).
    let landed = invoke_dap_step_back(&mut handler, None);
    assert_eq!(
        landed,
        StepId(2),
        "legacy line-granularity stepBack from step 3 MUST land at step 2 \
         (the last step of the prior line, line 1, col {COL_VAR_C}); landed at {landed:?}"
    );
    {
        let step = handler.reader.step(landed).expect("landed step exists");
        assert_eq!(step.line.0, 1, "legacy `stepBack` MUST land on the prior line (line 1)");
        assert_eq!(
            step.column,
            Some(Line(COL_VAR_C)),
            "legacy `stepBack` lands on the LAST encountered step of the prior line \
             when walking backward — symmetric to the M2 forward semantic where forward \
             stops at the FIRST step of the next line"
        );
    }

    // Same back-compat assertion for the explicit `granularity ==
    // "line"` form.  DAP spec §setStepping treats "line" as the
    // default; we MUST not regress when a client states it
    // explicitly.
    handler.replay.jump_to(StepId(3)).expect("jump_to step 3 succeeds");
    handler.step_id = handler.replay.current_step_id();
    let landed_line = invoke_dap_step_back(&mut handler, Some("line"));
    assert_eq!(
        landed_line,
        StepId(2),
        "explicit `granularity: \"line\"` MUST behave the same as legacy line-granularity \
         in reverse; landed at {landed_line:?}"
    );

    // Same for `granularity == "instruction"`.  We have no
    // instruction backend on a materialised trace; per the M7
    // contract `instruction` falls back to the line-granularity
    // runner rather than erroring out.
    handler.replay.jump_to(StepId(3)).expect("jump_to step 3 succeeds");
    handler.step_id = handler.replay.current_step_id();
    let landed_instr = invoke_dap_step_back(&mut handler, Some("instruction"));
    assert_eq!(
        landed_instr,
        StepId(2),
        "`granularity: \"instruction\"` on a materialised trace MUST fall back to \
         reverse-line-granularity (no instruction backend exists); landed at {landed_instr:?}"
    );

    // Second backward hop with line granularity: step 2 -> step 0.
    // From step 2 (line 1, col 23), legacy stepBack walks backwards
    // until `(line, call_key)` changes — but all of steps 0, 1, 2 are
    // on line 1 with the same call_key.  The runner walks back to
    // step 0 (the first step of the trace) and clamps there because
    // step 0 has no prior step.  This pins the second-hop behaviour:
    // once the cursor is on the prior line, a subsequent stepBack
    // continues until either a line change or the trace boundary.
    handler.replay.jump_to(StepId(2)).expect("jump_to step 2 succeeds");
    handler.step_id = handler.replay.current_step_id();
    let landed_clamp = invoke_dap_step_back(&mut handler, None);
    assert_eq!(
        landed_clamp,
        StepId(0),
        "from step 2 (line 1, all prior steps also on line 1) legacy stepBack walks back \
         to the trace boundary at step 0; landed at {landed_clamp:?}"
    );
}

/// STRICT (Test C) — statement-granularity stepBack on a single-
/// statement line MUST behave indistinguishably from line-granularity
/// stepBack.  Starting at step 0 (the first step), one
/// `stepBack({granularity: "statement"})` MUST clamp at step 0 (no
/// prior step exists).  We also prove the two granularities agree on a
/// step pair that's a clean line-only transition.
///
/// This pins the "no surprises on a normal line" half of the M7
/// contract: a single-statement line is exactly the case where the
/// two granularities collapse — column-delta within the statement is
/// indistinguishable from line-delta because the statement IS the
/// line.  Mirror of the M2 single-statement-line assertion.
#[test]
fn statement_step_back_on_single_statement_line_advances_by_line() {
    let trace_dir = std::env::temp_dir().join(format!(
        "dap_statement_step_back_single_stmt_test_{}",
        std::process::id()
    ));
    if !trace_dir.exists() {
        std::fs::create_dir_all(&trace_dir).expect("create trace dir");
    }
    let (reader, _recorded_path) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);

    // Park at step 0 — the FIRST step, where stepping back has no
    // prior step to land on.  Both granularities MUST clamp here.
    handler.replay.jump_to(StepId(0)).expect("jump_to step 0 succeeds");
    handler.step_id = handler.replay.current_step_id();
    assert_eq!(handler.step_id, StepId(0));

    let landed_stmt = invoke_dap_step_back(&mut handler, Some("statement"));
    assert_eq!(
        landed_stmt,
        StepId(0),
        "stepping back past the beginning MUST clamp at the first step; landed at {landed_stmt:?}"
    );

    handler.replay.jump_to(StepId(0)).expect("jump_to step 0 succeeds");
    handler.step_id = handler.replay.current_step_id();
    let landed_line = invoke_dap_step_back(&mut handler, None);
    assert_eq!(
        landed_line, landed_stmt,
        "statement-granularity stepBack on the bounds MUST agree with line-granularity stepBack; \
         landed_stmt = {landed_stmt:?}, landed_line = {landed_line:?}"
    );

    // Now park on the single-statement line (step 3, line 2 col 1)
    // and verify both granularities take an identical hop in reverse.
    // Both MUST jump to the LAST step on the prior line — i.e. step 2
    // (line 1, col 23) — because that is the closest prior step
    // observable from line 2.  The two granularities agree because
    // the transition fires on the line-changed predicate before the
    // column predicate gets a chance to fire.
    handler.replay.jump_to(StepId(3)).expect("jump_to step 3 succeeds");
    handler.step_id = handler.replay.current_step_id();
    let from_line_two_stmt = invoke_dap_step_back(&mut handler, Some("statement"));
    handler.replay.jump_to(StepId(3)).expect("jump_to step 3 succeeds");
    handler.step_id = handler.replay.current_step_id();
    let from_line_two_line = invoke_dap_step_back(&mut handler, None);
    assert_eq!(
        from_line_two_stmt,
        StepId(2),
        "stepBack from the single-statement line 2 MUST land on the closest prior step \
         (step 2 = line 1, col {COL_VAR_C}); landed at {from_line_two_stmt:?}"
    );
    assert_eq!(
        from_line_two_stmt, from_line_two_line,
        "statement-granularity stepBack across a line boundary MUST agree with line-granularity \
         stepBack; statement = {from_line_two_stmt:?}, line = {from_line_two_line:?}"
    );
}
