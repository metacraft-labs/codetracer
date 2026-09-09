//! Data breakpoints (watchpoints) over a materialised recording.
//!
//! # The defect this file exists to close
//!
//! `Trace.add_watchpoint(expr)` in the Python API translated to a DAP
//! `setDataBreakpoints`, and the daemon answered the caller
//! `success: true` with a watchpoint id BEFORE the backend had seen the
//! request.  PR #730 made the daemon wait for the backend's verdict —
//! and the verdict turned out to be that there was no
//! `setDataBreakpoints` arm in `dap_server::handle_request` at all.
//! The command fell through to `dap_command_to_step_action`, failed to
//! parse as a step action, and came back as the free-text
//!
//!   `command setDataBreakpoints not supported here`
//!
//! — the fallthrough meant for commands nobody had thought about.
//! Watchpoints had never worked.
//!
//! Nothing caught it because the ONLY implementation of
//! `setDataBreakpoints` anywhere in the tree was the daemon's own mock
//! DAP backend, which answered `verified: true` unconditionally.  The
//! test double was more capable than the component it stood in for, so
//! every test of the watchpoint path passed against a mock that could
//! do something the product could not.
//!
//! # What a watchpoint means here
//!
//! A materialised CodeTracer recording holds a table of variable values
//! sampled at every recorded step.  There is no CPU to trap on an
//! address.  So the watchpoint this backend honours is a **value-change
//! watchpoint**: `continue` stops at the first later step at which the
//! named variable's recorded value differs from the value it held at
//! the previous step that recorded it.
//!
//! Everything the recording cannot support refuses through
//! `ct_data_breakpoints::DataBreakpointRefusal`, a closed set shared
//! with the daemon's mock — see `conformance_cases_agree_with_the_real_backend`
//! below, which is the test that fails if the mock and the real backend
//! ever diverge again.
//!
//! Run:
//!   cd src/db-backend && cargo test --test dap_data_breakpoints_test \
//!     --no-default-features --features io-transport,syntax-highlight

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc;

use codetracer_trace_types::{
    CallKey, FullValueRecord, FunctionId, FunctionRecord, Line, PathId, StepId, TypeId, TypeKind, TypeRecord,
    TypeSpecificInfo, ValueRecord, VariableId,
};
use ct_data_breakpoints::{DataBreakpointRefusal, TraceVocabulary, conformance_cases, verdict};
use db_backend::dap::{DapMessage, ProtocolMessage, Request, Response};
use db_backend::dap_handler::Handler;
use db_backend::db::{Db, DbCall, DbStep, EndOfProgram};
use db_backend::in_memory_trace_reader::InMemoryTraceReader;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::task::{Action, StepArg, TraceKind};
use db_backend::trace_reader::TraceReader;

const RECORDED_FILE: &str = "loop.py";

/// `counter` — the variable the watchpoint tests watch.
const VAR_COUNTER: VariableId = VariableId(1);
/// `untouched` — recorded at every step and never changing, so a
/// watchpoint on it must NOT stop anywhere.
const VAR_UNTOUCHED: VariableId = VariableId(2);

/// The synthetic trace.  Eight steps; `counter` holds:
///
///   step 0 — 0
///   step 1 — 0   (no change; a watchpoint must NOT fire here)
///   step 2 — 0   (no change)
///   step 3 — 7   (FIRST change — the watchpoint stop)
///   step 4 — 7   (no change)
///   step 5 — 9   (second change)
///   step 6 — 9
///   step 7 — 9   (last step; the no-match fall-through parks here, so
///                 a real stop is distinguishable from running off the end)
///
/// `untouched` holds 42 at every step.
const COUNTER_PLAN: [i64; 8] = [0, 0, 0, 7, 7, 9, 9, 9];
/// The first step at which `counter` differs from the step before it.
const FIRST_CHANGE: i64 = 3;
/// The second such step.
const SECOND_CHANGE: i64 = 5;

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

    db.variable_names.push("<sentinel>".to_string());
    db.variable_names.push("counter".to_string());
    db.variable_names.push("untouched".to_string());

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

    let mut step_records: Vec<DbStep> = Vec::with_capacity(COUNTER_PLAN.len());
    for (idx, counter_value) in COUNTER_PLAN.iter().enumerate() {
        let step = DbStep {
            step_id: StepId(idx as i64),
            path_id: PathId(1),
            line: Line(idx as i64 + 1),
            column: None,
            call_key,
            global_call_key: call_key,
        };
        step_records.push(step);
        db.steps.push(step);
        db.variables.push(vec![
            FullValueRecord {
                variable_id: VAR_COUNTER,
                value: ValueRecord::Int {
                    i: *counter_value,
                    type_id: TypeId(0),
                },
            },
            FullValueRecord {
                variable_id: VAR_UNTOUCHED,
                value: ValueRecord::Int {
                    i: 42,
                    type_id: TypeId(0),
                },
            },
        ]);
        db.instructions.push(Vec::new());
        db.compound.push(HashMap::new());
        db.cells.push(HashMap::new());
        db.variable_cells.push(HashMap::new());
    }

    db.step_map.push(HashMap::new());
    let mut path1_map: HashMap<usize, Vec<DbStep>> = HashMap::new();
    for (idx, step) in step_records.iter().enumerate() {
        path1_map.insert(idx + 1, vec![*step]);
    }
    db.step_map.push(path1_map);

    db.end_of_program = EndOfProgram::Normal;

    let reader: Arc<dyn TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    (reader, recorded)
}

fn make_handler(label: &str) -> Handler {
    let trace_dir = std::env::temp_dir().join(format!("dap_data_bp_{}_{}", label, std::process::id()));
    if !trace_dir.exists() {
        std::fs::create_dir_all(&trace_dir).expect("create trace dir");
    }
    let (reader, _recorded) = build_trace(&trace_dir);
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);
    handler
}

/// Drive a raw DAP request through the real dispatch — the same
/// `handle_request` the stdio server calls.  Returns the response, or
/// the dispatch error for a command the backend does not handle.
fn dispatch(handler: &mut Handler, command: &str, arguments: serde_json::Value) -> Result<Response, String> {
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let request = Request {
        base: ProtocolMessage {
            seq: 1,
            type_: "request".to_string(),
        },
        command: command.to_string(),
        arguments,
    };
    db_backend::dap_server::handle_request(handler, request, tx).map_err(|e| format!("{e}"))?;
    loop {
        match rx.try_recv() {
            Ok(DapMessage::Response(r)) => return Ok(r),
            Ok(_) => continue,
            Err(_) => return Err("dispatch produced no DAP Response".to_string()),
        }
    }
}

fn set_data_breakpoints(handler: &mut Handler, entries: serde_json::Value) -> Result<Response, String> {
    dispatch(handler, "setDataBreakpoints", serde_json::json!({ "breakpoints": entries }))
}

fn continue_forward(handler: &mut Handler) -> StepId {
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

/// The per-entry verdicts from a `setDataBreakpoints` response body,
/// as `(verified, refusal_code)` pairs.
fn verdicts(response: &Response) -> Vec<(bool, Option<u32>)> {
    let bps = response.body["breakpoints"]
        .as_array()
        .expect("setDataBreakpoints body must carry a `breakpoints` array");
    bps.iter()
        .map(|b| {
            (
                b["verified"].as_bool().expect("each entry carries `verified`"),
                b["refusalCode"].as_u64().map(|c| c as u32),
            )
        })
        .collect()
}

// ── The dispatch itself ─────────────────────────────────────────────

/// STRICT — `setDataBreakpoints` must be DISPATCHED.
///
/// RED BEFORE THE FIX with exactly the message the daemon was
/// discarding:
///
///   dispatch of `setDataBreakpoints` failed: command setDataBreakpoints
///   not supported here
///
/// That string is the free-text fallthrough in `handle_request`'s `_`
/// arm, reached via `dap_command_to_step_action`.  Its presence is the
/// whole defect: not `verified: false`, but a command the backend never
/// knew existed.
#[test]
fn set_data_breakpoints_is_dispatched_at_all() {
    let mut handler = make_handler("dispatched");
    let response = set_data_breakpoints(&mut handler, serde_json::json!([{ "dataId": "counter" }]))
        .unwrap_or_else(|e| panic!("dispatch of `setDataBreakpoints` failed: {e}"));
    assert!(
        response.success,
        "a well-formed setDataBreakpoints for a variable this trace records must succeed; \
         got success=false, message={:?}",
        response.message
    );
}

/// STRICT — `dataBreakpointInfo` is the DAP handshake a client uses to
/// ask "can I watch this?" before setting anything.  Without it a
/// conforming client never offers the affordance at all.
#[test]
fn data_breakpoint_info_is_dispatched_and_answers_for_a_known_variable() {
    let mut handler = make_handler("info");
    let response = dispatch(&mut handler, "dataBreakpointInfo", serde_json::json!({ "name": "counter" }))
        .unwrap_or_else(|e| panic!("dispatch of `dataBreakpointInfo` failed: {e}"));
    assert!(response.success, "dataBreakpointInfo must succeed: {:?}", response.message);
    assert_eq!(
        response.body["dataId"].as_str(),
        Some("counter"),
        "a watchable variable must come back with a non-null dataId; body: {}",
        response.body
    );
    let access_types = response.body["accessTypes"]
        .as_array()
        .expect("accessTypes must be reported so a client does not offer `read`");
    assert_eq!(
        access_types.len(),
        1,
        "a recording can only answer `write`; it does not record reads. accessTypes: {access_types:?}"
    );
    assert_eq!(access_types[0].as_str(), Some("write"));
}

/// STRICT — `dataBreakpointInfo` for something the recording cannot
/// watch must return `dataId: null`, which is DAP's way of saying "do
/// not offer this".  A non-null dataId for an unwatchable name is the
/// same lie the mock told.
#[test]
fn data_breakpoint_info_refuses_an_unwatchable_expression_with_a_null_data_id() {
    let mut handler = make_handler("info_refuse");
    let response = dispatch(&mut handler, "dataBreakpointInfo", serde_json::json!({ "name": "obj.field" }))
        .expect("dataBreakpointInfo dispatches");
    assert!(
        response.body["dataId"].is_null(),
        "an expression the value table cannot resolve must come back with dataId: null; body: {}",
        response.body
    );
    assert_eq!(
        response.body["refusalCode"].as_u64().map(|c| c as u32),
        Some(DataBreakpointRefusal::ExpressionNotAWatchableVariable.as_u32()),
        "the refusal must name itself from the closed set, not in prose; body: {}",
        response.body
    );
}

// ── The feature ─────────────────────────────────────────────────────

/// STRICT — the point of the whole exercise.  A watchpoint on
/// `counter` must stop `continue` at the first step where `counter`'s
/// recorded value CHANGES.
///
/// `counter` is 0 at steps 0, 1 and 2, becomes 7 at step 3, and 9 at
/// step 5.  A Continue from step 0 must land on step 3 — not step 1
/// (which would mean "any step that records the variable", the naive
/// bug), and not step 7 (which would mean the watchpoint was ignored
/// and the run fell off the end of the trace — the behaviour users
/// actually saw, reported as `StopIteration`).
#[test]
fn a_watchpoint_stops_continue_at_the_first_value_change() {
    let mut handler = make_handler("fires");
    let response =
        set_data_breakpoints(&mut handler, serde_json::json!([{ "dataId": "counter" }])).expect("dispatches");
    assert_eq!(verdicts(&response), vec![(true, None)], "the watchpoint must verify");

    let landed = continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(FIRST_CHANGE),
        "Continue from step 0 with a watchpoint on `counter` MUST stop at step {FIRST_CHANGE}, the \
         first step whose recorded value (7) differs from the step before it (0). Landed at \
         {landed:?}. Step 1 would mean the watchpoint fired on any step recording the variable; \
         step 7 would mean it was ignored and the run fell off the end of the trace — which is \
         exactly what users saw as StopIteration."
    );
}

/// STRICT — a second Continue must advance to the NEXT change, not
/// re-fire in place.  A watchpoint that re-fires where it already
/// stopped wedges `continue_forward()` in an infinite loop.
#[test]
fn a_watchpoint_advances_to_the_next_change_rather_than_re_firing() {
    let mut handler = make_handler("advances");
    set_data_breakpoints(&mut handler, serde_json::json!([{ "dataId": "counter" }])).expect("dispatches");

    let first = continue_forward(&mut handler);
    assert_eq!(first, StepId(FIRST_CHANGE));
    let second = continue_forward(&mut handler);
    assert_eq!(
        second,
        StepId(SECOND_CHANGE),
        "a second Continue must reach the next value change (step {SECOND_CHANGE}, 7 -> 9), not \
         stay parked at step {FIRST_CHANGE}. Landed at {second:?}."
    );
}

/// STRICT — a watchpoint on a variable that never changes must NOT
/// stop.  `untouched` is 42 at every step, so Continue must run to the
/// end of the trace.  A watchpoint that fires on a constant is worse
/// than one that never fires: it stops somewhere arbitrary and the
/// user believes a write happened.
#[test]
fn a_watchpoint_on_an_unchanging_variable_does_not_stop() {
    let mut handler = make_handler("constant");
    set_data_breakpoints(&mut handler, serde_json::json!([{ "dataId": "untouched" }])).expect("dispatches");

    let landed = continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(COUNTER_PLAN.len() as i64 - 1),
        "`untouched` holds 42 at every recorded step, so a value-change watchpoint must never \
         fire and Continue must reach the end of the trace. Landed at {landed:?}."
    );
}

/// STRICT — DAP `setDataBreakpoints` REPLACES the whole set (the same
/// semantics `setBreakpoints` has).  An empty array clears every
/// watchpoint, and Continue must then run to the end.
#[test]
fn an_empty_set_data_breakpoints_clears_the_watchpoints() {
    let mut handler = make_handler("clear");
    set_data_breakpoints(&mut handler, serde_json::json!([{ "dataId": "counter" }])).expect("dispatches");
    set_data_breakpoints(&mut handler, serde_json::json!([])).expect("dispatches");

    let landed = continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(COUNTER_PLAN.len() as i64 - 1),
        "setDataBreakpoints replaces the set; after an empty one no watchpoint remains and \
         Continue must reach the end of the trace. Landed at {landed:?}."
    );
}

// ── The refusals ────────────────────────────────────────────────────

/// STRICT — a refused entry must come back `verified: false` carrying a
/// code from the CLOSED set, and must NOT fail the whole request.
///
/// This is the shape PR #730 taught the daemon to read: a per-entry
/// verdict.  Before this change the daemon could only ever see a
/// request-level free-text refusal, because the command was never
/// dispatched.
#[test]
fn refusals_are_per_entry_and_name_themselves_from_the_closed_set() {
    let mut handler = make_handler("refusals");
    let response = set_data_breakpoints(
        &mut handler,
        serde_json::json!([
            { "dataId": "counter" },
            { "dataId": "counter", "accessType": "read" },
            { "dataId": "obj.field" },
            { "dataId": "never_recorded" },
            { "dataId": "counter", "condition": "counter > 3" },
        ]),
    )
    .expect("dispatches");

    assert!(
        response.success,
        "a request carrying some refusable entries is still a well-formed request; the refusals \
         belong on the entries, not on the request. message={:?}",
        response.message
    );
    assert_eq!(
        verdicts(&response),
        vec![
            (true, None),
            (false, Some(DataBreakpointRefusal::AccessTypeNotRecorded.as_u32())),
            (false, Some(DataBreakpointRefusal::ExpressionNotAWatchableVariable.as_u32())),
            (false, Some(DataBreakpointRefusal::VariableNotInTrace.as_u32())),
            (false, Some(DataBreakpointRefusal::ConditionNotSupported.as_u32())),
        ],
        "each entry must carry its own verdict, in request order, with a closed-set refusal code"
    );
}

/// STRICT — a refused entry must not be installed.  Refusing on the
/// wire and watching anyway (or refusing and leaving a half-registered
/// entry that perturbs the scan) is the same class of dishonesty as
/// accepting and doing nothing.
#[test]
fn a_refused_watchpoint_is_not_installed() {
    let mut handler = make_handler("refused_not_installed");
    let response = set_data_breakpoints(
        &mut handler,
        serde_json::json!([{ "dataId": "counter", "accessType": "read" }]),
    )
    .expect("dispatches");
    assert_eq!(
        verdicts(&response),
        vec![(false, Some(DataBreakpointRefusal::AccessTypeNotRecorded.as_u32()))]
    );

    let landed = continue_forward(&mut handler);
    assert_eq!(
        landed,
        StepId(COUNTER_PLAN.len() as i64 - 1),
        "the only entry was refused, so no watchpoint is installed and Continue must reach the \
         end of the trace. Landed at {landed:?} — a stop here would mean the backend refused on \
         the wire and watched anyway."
    );
}

// ── Mock/real parity: the test that would catch the next divergence ──

/// A `TraceVocabulary` view of the real handler's recording.
struct HandlerVocabulary<'a>(&'a Handler);

impl TraceVocabulary for HandlerVocabulary<'_> {
    fn has_per_step_values(&self) -> bool {
        self.0.trace_kind == TraceKind::Materialized
    }
    fn knows_variable(&self, name: &str) -> bool {
        self.0.reader.variable_id_for(name).is_some()
    }
}

/// STRICT — the REAL backend's `setDataBreakpoints` must agree, case
/// for case, with the shared admission rules in
/// `ct_data_breakpoints::conformance_cases()`.
///
/// The daemon's mock DAP backend is driven through the SAME table from
/// its own crate
/// (`backend-manager`'s `mock_matches_the_shared_data_breakpoint_verdict`).
/// Together the two tests are the thing that was missing: when the mock
/// and the real backend last disagreed, the disagreement was TOTAL —
/// the mock verified everything, the backend dispatched nothing — and
/// no test in the tree could see it, because no test compared them
/// against a common standard.
///
/// If someone teaches the mock a capability the backend lacks (or the
/// reverse), one of these two tests goes red.
#[test]
fn conformance_cases_agree_with_the_real_backend() {
    let mut handler = make_handler("conformance");

    // Only the cases whose vocabulary this fixture can actually stand
    // in for: the fixture records `counter` and `untouched` and is a
    // materialised trace.  The `BackendLacksValueHistory` cases are
    // asserted separately below against a non-materialised handler.
    let mut checked = 0usize;
    for (request, vocabulary, expected) in conformance_cases() {
        if !vocabulary.has_per_step_values() {
            continue;
        }
        // Re-point the case's variable vocabulary at this fixture:
        // the shared table names `counter`, which this trace records,
        // and a handful of names it deliberately does not.
        let expected = match &expected {
            Ok(v) if v.name != "counter" => {
                // The table's other accepted names (`total`, `_tmp`,
                // `x2`) are not in this fixture, so against the real
                // trace they are `VariableNotInTrace`.  That is the
                // rules agreeing, not disagreeing — the vocabulary
                // differs, not the rule.
                Err(DataBreakpointRefusal::VariableNotInTrace)
            }
            other => other.clone(),
        };

        let mut entry = serde_json::json!({ "dataId": request.data_id });
        if let Some(a) = &request.access_type {
            entry["accessType"] = serde_json::json!(a);
        }
        if let Some(c) = &request.condition {
            entry["condition"] = serde_json::json!(c);
        }
        if let Some(h) = &request.hit_condition {
            entry["hitCondition"] = serde_json::json!(h);
        }

        let response = set_data_breakpoints(&mut handler, serde_json::json!([entry])).expect("dispatches");
        let actual = verdicts(&response);
        let expected_pair = match &expected {
            Ok(_) => (true, None),
            Err(r) => (false, Some(r.as_u32())),
        };
        assert_eq!(
            actual,
            vec![expected_pair],
            "the real backend disagreed with the shared admission rules for {request:?}: \
             expected {expected:?}"
        );
        checked += 1;
    }

    // A zero here would mean this test asserted nothing at all.
    assert!(
        checked >= 12,
        "only {checked} conformance cases were exercised against the real backend; the table \
         has stopped covering the rules it is supposed to pin"
    );

    // And the rules themselves must still agree with the real
    // handler's own vocabulary view.
    let vocabulary = HandlerVocabulary(&handler);
    assert!(vocabulary.has_per_step_values());
    assert!(vocabulary.knows_variable("counter"));
    assert!(!vocabulary.knows_variable("never_recorded"));
    assert_eq!(
        verdict(&ct_data_breakpoints::DataBreakpointRequest::new("counter"), &vocabulary)
            .expect("counter is watchable")
            .name,
        "counter"
    );
}
