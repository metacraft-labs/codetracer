//! `ct/load-step-lines` answers the executed lines around a location.
//!
//! The Step List pane asks for the rows it shows, either side of the current
//! step (Viewport-Driven-Loading V1/V2: its measured height is sent as both
//! `backwardCount` and `forwardCount`). These tests pin what the answer is:
//! the steps in `[rrTicks - backwardCount, rrTicks + forwardCount)`, each with
//! its `delta` relative to the requested step and its source text, a
//! synthesised `Call` / `Return` row wherever the call depth changes, the
//! requested location echoed back, and the whole window in one response.
//!
//! The handler is built over an in-memory materialized trace — two calls,
//! five steps — because the property is the request handling and the line
//! walk, which need no recorded program; the source file is written to disk
//! because the loader reads each step's text from it, as it does for a real
//! recording. Nothing is mocked: the request goes through `Handler`'s real
//! `load_step_lines` and its real `StepLinesLoader`.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::collections::HashMap;
use std::sync::{Arc, mpsc};

use codetracer_trace_types::{
    CallKey, FunctionId, FunctionRecord, Line, PathId, StepId, TypeId, TypeKind, TypeRecord, TypeSpecificInfo,
    ValueRecord,
};
use db_backend::dap::{DapMessage, ProtocolMessage, Request};
use db_backend::dap_handler::Handler;
use db_backend::db::{Db, DbCall, DbStep, EndOfProgram};
use db_backend::in_memory_trace_reader::InMemoryTraceReader;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::task::{LoadStepLinesArg, Location, RRTicks, TraceKind};
use db_backend::trace_reader::TraceReader;
use serde_json::Value as JsonValue;

const SOURCE: &str = "a = 1\nb = helper(a)\nprint(b)\n\n\n\n\n\n\ndef helper(x):\n  y = x + 1\n  return y\n";

/// `main` runs lines 1, 2, then `helper` (depth 1) runs lines 11 and 12,
/// then `main` resumes on line 3:
///
/// | step | line | call      | depth |
/// |------|------|-----------|-------|
/// | 0    | 1    | main (0)  | 0     |
/// | 1    | 2    | main (0)  | 0     |
/// | 2    | 11   | helper (1)| 1     |
/// | 3    | 12   | helper (1)| 1     |
/// | 4    | 3    | main (0)  | 0     |
fn build_trace(dir: &std::path::Path) -> (Arc<dyn TraceReader>, String) {
    let recorded = dir.join("program.py").display().to_string();
    std::fs::write(&recorded, SOURCE).expect("write source");
    let mut db = Db::new(&dir.to_path_buf());
    db.paths.push(String::new());
    db.paths.push(recorded.clone());
    db.register_path_version(recorded.clone(), PathId(1));
    db.types.push(TypeRecord {
        kind: TypeKind::Int,
        lang_type: "int".to_string(),
        specific_info: TypeSpecificInfo::None,
    });
    db.functions.push(FunctionRecord {
        path_id: PathId(1),
        line: Line(1),
        name: "main".to_string(),
    });
    db.functions.push(FunctionRecord {
        path_id: PathId(1),
        line: Line(10),
        name: "helper".to_string(),
    });
    db.calls.push(DbCall {
        key: CallKey(0),
        function_id: FunctionId(0),
        args: Vec::new(),
        return_value: ValueRecord::None { type_id: TypeId(0) },
        step_id: StepId(0),
        depth: 0,
        parent_key: CallKey(-1),
        children_keys: vec![CallKey(1)],
    });
    db.calls.push(DbCall {
        key: CallKey(1),
        function_id: FunctionId(1),
        args: Vec::new(),
        return_value: ValueRecord::None { type_id: TypeId(0) },
        step_id: StepId(2),
        depth: 1,
        parent_key: CallKey(0),
        children_keys: Vec::new(),
    });
    let make_step = |id: i64, line: i64, call: i64| DbStep {
        step_id: StepId(id),
        path_id: PathId(1),
        line: Line(line),
        column: None,
        call_key: CallKey(call),
        global_call_key: CallKey(call),
    };
    let steps = [
        make_step(0, 1, 0),
        make_step(1, 2, 0),
        make_step(2, 11, 1),
        make_step(3, 12, 1),
        make_step(4, 3, 0),
    ];
    let mut path_map: HashMap<usize, Vec<DbStep>> = HashMap::new();
    for step in steps.iter() {
        db.steps.push(*step);
        db.variables.push(Vec::new());
        db.instructions.push(Vec::new());
        db.compound.push(HashMap::new());
        db.cells.push(HashMap::new());
        db.variable_cells.push(HashMap::new());
        path_map.entry(step.line.0 as usize).or_default().push(*step);
    }
    db.step_map.push(HashMap::new());
    db.step_map.push(path_map);
    db.end_of_program = EndOfProgram::Normal;
    (Arc::new(InMemoryTraceReader::new(db)), recorded)
}

fn request(arg: &LoadStepLinesArg) -> Request {
    Request {
        base: ProtocolMessage {
            seq: 7,
            type_: "request".to_string(),
        },
        command: "ct/load-step-lines".to_string(),
        arguments: serde_json::to_value(arg).expect("serialize arg"),
    }
}

/// Sends the request through `Handler::load_step_lines` and returns the one
/// response's `(success, message, body)`.
fn send(handler: &mut Handler, arg: &LoadStepLinesArg) -> (bool, Option<String>, JsonValue) {
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let req = request(arg);
    let parsed: LoadStepLinesArg = req.load_args().expect("the arm's own argument decode");
    handler.load_step_lines(req, parsed, tx).expect("load_step_lines");
    let mut found = None;
    while let Ok(msg) = rx.try_recv() {
        if let DapMessage::Response(resp) = msg
            && resp.command == "ct/load-step-lines"
        {
            assert!(found.is_none(), "more than one ct/load-step-lines response");
            found = Some((resp.success, resp.message.clone(), resp.body));
        }
    }
    found.expect("no ct/load-step-lines response")
}

fn location_at(reader: &Arc<dyn TraceReader>, step: i64, path: &str) -> Location {
    let step_record = reader.step(StepId(step)).expect("step");
    Location {
        path: path.to_string(),
        line: step_record.line.0,
        rr_ticks: RRTicks(step),
        callstack_depth: if step_record.call_key == CallKey(1) { 1 } else { 0 },
        function_name: if step_record.call_key == CallKey(1) {
            "helper".to_string()
        } else {
            "main".to_string()
        },
        ..Location::default()
    }
}

/// `(kind, delta, line, sourceLine)` of every answered row.
fn rows(body: &JsonValue) -> Vec<(i64, i64, i64, String)> {
    body["results"]
        .as_array()
        .expect("results")
        .iter()
        .map(|r| {
            (
                r["kind"].as_i64().expect("kind"),
                r["delta"].as_i64().expect("delta"),
                r["location"]["line"].as_i64().expect("line"),
                r["sourceLine"].as_str().expect("sourceLine").to_string(),
            )
        })
        .collect()
}

const LINE: i64 = 0;
const CALL: i64 = 1;
const RETURN: i64 = 2;

#[test]
fn the_window_around_a_step_is_its_lines_with_call_and_return_rows() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (reader, path) = build_trace(dir.path());
    let mut handler = Handler::construct_with_reader(
        TraceKind::Materialized,
        RecreatorArgs::default(),
        Arc::clone(&reader),
        false,
    );

    // Two rows either side of step 2 (the first line of `helper`): steps
    // 0..=3 — the window is `[2 - 2, 2 + 2)`.
    let arg = LoadStepLinesArg {
        location: location_at(&reader, 2, &path),
        backward_count: 2,
        forward_count: 2,
    };
    let (success, message, body) = send(&mut handler, &arg);
    assert!(success, "ct/load-step-lines failed: {message:?}");

    // The request started inside `helper` (depth 1), so the walk first sees
    // `main`'s depth-0 lines as a return out of `helper`, then the call into
    // it again: a row per depth change, carrying its step's delta.
    assert_eq!(
        rows(&body),
        vec![
            (RETURN, -2, 1, "return from call helper".to_string()),
            (LINE, -2, 1, "a = 1".to_string()),
            (LINE, -1, 2, "b = helper(a)".to_string()),
            (CALL, 0, 11, "call helper".to_string()),
            (LINE, 0, 11, "  y = x + 1".to_string()),
            (LINE, 1, 12, "  return y".to_string()),
        ]
    );
    assert_eq!(body["argLocation"]["rrTicks"], 2, "the requested location is echoed");
    assert_eq!(body["finish"], true, "the whole window is one answer");
}

#[test]
fn the_window_is_clipped_at_both_ends_of_the_trace() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (reader, path) = build_trace(dir.path());
    let mut handler = Handler::construct_with_reader(
        TraceKind::Materialized,
        RecreatorArgs::default(),
        Arc::clone(&reader),
        false,
    );

    // Ten rows either side of step 4 cannot go before step 0 or past the
    // last step; the deltas stay relative to the requested step.
    let arg = LoadStepLinesArg {
        location: location_at(&reader, 4, &path),
        backward_count: 10,
        forward_count: 10,
    };
    let (success, message, body) = send(&mut handler, &arg);
    assert!(success, "ct/load-step-lines failed: {message:?}");
    let lines: Vec<(i64, i64)> = rows(&body)
        .into_iter()
        .filter(|r| r.0 == LINE)
        .map(|r| (r.1, r.2))
        .collect();
    assert_eq!(lines, vec![(-4, 1), (-3, 2), (-2, 11), (-1, 12), (0, 3)]);
    let events: Vec<(i64, i64)> = rows(&body)
        .into_iter()
        .filter(|r| r.0 != LINE)
        .map(|r| (r.0, r.1))
        .collect();
    assert_eq!(
        events,
        vec![(CALL, -2), (RETURN, 0)],
        "one call into helper, one return"
    );
}

#[test]
fn a_trace_that_is_not_materialized_is_refused_by_name() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (reader, path) = build_trace(dir.path());
    let mut handler = Handler::construct_with_reader(
        TraceKind::Recreator,
        RecreatorArgs::default(),
        Arc::clone(&reader),
        false,
    );
    let arg = LoadStepLinesArg {
        location: location_at(&reader, 0, &path),
        backward_count: 1,
        forward_count: 1,
    };
    let (success, message, _) = send(&mut handler, &arg);
    assert!(!success, "a non-materialized trace must not be answered");
    let message = message.unwrap_or_default();
    assert!(message.contains("materialized"), "unexpected refusal: {message}");
}
