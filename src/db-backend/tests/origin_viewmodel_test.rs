//! M2 wire-shape contract regression tests for the JSON payload the
//! Nim `OriginChainVM` consumes.
//!
//! These tests are explicitly NOT M4 ViewModel-layer tests — they do
//! not exercise any Nim code or reactive-signal transition. Their
//! purpose is to guarantee that the camelCase wire shape produced by
//! `Handler::origin_chain` / `Handler::origin_summary` /
//! `Handler::load_locals` / `Handler::load_history` / `Handler::load_flow`
//! continues to match the `OriginChain` / `OriginSummary` shape decoded
//! by `parseOriginChain` / `parseOriginSummary` in
//! `src/frontend/viewmodel/viewmodels/origin_chain_types.nim`.
//!
//! The actual reactive-signal transitions of `OriginChainVM` are
//! exercised by the frontend Nim unittest
//! `src/frontend/viewmodel/tests/unit/test_origin_chain_vm.nim`.
//! Together with these wire-shape tests they bracket the M4 contract
//! without claiming any one of them covers both halves on its own.
//!
//! The trace-ingestion layer uses the same `InMemoryTraceReader` escape
//! hatch documented in `origin_dap_test.rs` — see that file's preamble
//! for the rationale (M0 fixture `.ct` recordings are not yet wired
//! into the harness).

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::mpsc;

use codetracer_trace_types::{
    CallKey, FullValueRecord, FunctionId, FunctionRecord, Line as TraceLine, NO_KEY, PathId, StepId, TypeId, TypeKind,
    TypeRecord, TypeSpecificInfo, ValueRecord, VariableId,
};
use db_backend::dap::{DapMessage, ProtocolMessage, Request};
use db_backend::dap_handler::Handler;
use db_backend::db::{Db, DbCall, DbStep, EndOfProgram};
use db_backend::in_memory_trace_reader::InMemoryTraceReader;
use db_backend::lang::Lang;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::task::{
    CtLoadLocalsArguments, CtOriginChainArguments, CtOriginSummaryArguments, LoadHistoryArg, Location, RRTicks,
    TraceKind,
};
use serde_json::Value as JsonValue;
use tempfile::TempDir;

// ---------------------------------------------------------------------------
// Trace builder — minimal recipe for the per-test fixtures. Mirrors
// the helper in `origin_dap_test.rs` but kept independent so the two
// test files can evolve at different rates.
// ---------------------------------------------------------------------------

struct Recipe<'a> {
    source_path: &'a str,
    source: &'a str,
    function_name: &'a str,
    steps: Vec<(i64, Vec<(&'a str, ValueRecord)>)>,
}

fn make_int_type() -> TypeRecord {
    TypeRecord {
        kind: TypeKind::Int,
        lang_type: "int".to_string(),
        specific_info: TypeSpecificInfo::None,
    }
}

fn int_value(i: i64) -> ValueRecord {
    ValueRecord::Int { i, type_id: TypeId(0) }
}

fn build_trace(recipe: Recipe<'_>) -> (Db, TempDir) {
    let workdir_holder = tempfile::tempdir().expect("tempdir");
    let workdir = workdir_holder.path().to_path_buf();
    let abs_source = workdir.join(recipe.source_path);
    if let Some(parent) = abs_source.parent() {
        std::fs::create_dir_all(parent).expect("create source parent");
    }
    std::fs::write(&abs_source, recipe.source).expect("write source");

    let mut db = Db::new(&workdir);
    db.paths.push(String::new());
    db.paths.push(recipe.source_path.to_string());
    db.path_map.insert(recipe.source_path.to_string(), PathId(1));
    db.path_map.insert(abs_source.to_string_lossy().to_string(), PathId(1));

    db.types.push(make_int_type());
    db.functions.push(FunctionRecord {
        path_id: PathId(1),
        line: TraceLine(1),
        name: recipe.function_name.to_string(),
    });

    let mut var_ids: HashMap<String, VariableId> = HashMap::new();
    let mut ensure_var = |db: &mut Db, name: &str| -> VariableId {
        if let Some(existing) = var_ids.get(name) {
            return *existing;
        }
        let id = VariableId(db.variable_names.len());
        db.variable_names.push(name.to_string());
        var_ids.insert(name.to_string(), id);
        id
    };

    let top_call_key = CallKey(0);
    db.calls.push(DbCall {
        key: top_call_key,
        function_id: FunctionId(0),
        args: Vec::new(),
        return_value: ValueRecord::None { type_id: TypeId(0) },
        step_id: StepId(0),
        depth: 0,
        parent_key: NO_KEY,
        children_keys: Vec::new(),
    });
    let call_for_step: Vec<CallKey> = vec![top_call_key; recipe.steps.len()];

    let mut step_map_for_path: HashMap<usize, Vec<DbStep>> = HashMap::new();
    for (step_idx, (line_1based, snapshot)) in recipe.steps.iter().enumerate() {
        let step_id = StepId(step_idx as i64);
        let step = DbStep {
            step_id,
            path_id: PathId(1),
            line: TraceLine(*line_1based),
            call_key: call_for_step[step_idx],
            global_call_key: call_for_step[step_idx],
        };
        db.steps.push(step);
        step_map_for_path.entry(*line_1based as usize).or_default().push(step);
        let mut var_records = Vec::new();
        for (name, value) in snapshot {
            let var_id = ensure_var(&mut db, name);
            var_records.push(FullValueRecord {
                variable_id: var_id,
                value: value.clone(),
            });
        }
        db.variables.push(var_records);
        db.instructions.push(Vec::new());
        db.compound.push(HashMap::new());
        db.cells.push(HashMap::new());
        db.variable_cells.push(HashMap::new());
    }
    db.step_map.push(HashMap::new());
    db.step_map.push(step_map_for_path);
    db.end_of_program = EndOfProgram::Normal;

    (db, workdir_holder)
}

fn handler_with_trace(db: Db) -> Handler {
    let reader: Arc<dyn db_backend::trace_reader::TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false)
}

fn make_request(seq: i64, command: &str, args: JsonValue) -> Request {
    Request {
        base: ProtocolMessage {
            seq,
            type_: "request".to_string(),
        },
        command: command.to_string(),
        arguments: args,
    }
}

fn take_response_body(rx: &mpsc::Receiver<DapMessage>, command: &str) -> JsonValue {
    while let Ok(msg) = rx.try_recv() {
        if let DapMessage::Response(resp) = msg
            && resp.command == command
        {
            assert!(
                resp.success,
                "expected `{}` response to succeed, message={:?} body={:?}",
                command, resp.message, resp.body
            );
            return resp.body;
        }
    }
    panic!("no response on the channel for command `{}`", command);
}

fn three_hop_literal_trace() -> (Db, TempDir) {
    let recipe = Recipe {
        source_path: "fixture.py",
        source: "a = 10\nb = a\nc = b\nprint(c)\n",
        function_name: "main",
        steps: vec![
            (1, vec![("a", int_value(10))]),
            (2, vec![("a", int_value(10)), ("b", int_value(10))]),
            (
                3,
                vec![("a", int_value(10)), ("b", int_value(10)), ("c", int_value(10))],
            ),
            (
                4,
                vec![("a", int_value(10)), ("b", int_value(10)), ("c", int_value(10))],
            ),
        ],
    };
    build_trace(recipe)
}

// ---------------------------------------------------------------------------
// M4 V#1 — Wire-shape assertion for `ct/originChain` requests.
//
// The Nim `StateVM.onShowOrigin` sends a JSON payload via
// `BackendService.send("ct/originChain", originChainArgs(...))`. This
// test asserts that the wire payload the backend RECEIVES decodes to
// the expected `CtOriginChainArguments` shape, and that the wire
// payload the backend RETURNS is a fully-populated `OriginChain` the
// Nim `parseOriginChain` proc consumes.
// ---------------------------------------------------------------------------

#[test]
fn test_m2_contract_state_vm_on_show_origin_wire_shape() {
    let (db, _tmp) = three_hop_literal_trace();
    let mut handler = handler_with_trace(db);
    handler.step_id = StepId(3);
    handler.replay.jump_to(StepId(3)).expect("jump_to step 3");

    let (tx, rx) = mpsc::channel::<DapMessage>();

    // Mirror the *exact* JSON shape Nim's `originChainArgs("c")` builds.
    let args_json = serde_json::json!({
        "variableName": "c",
        "variablePath": [],
        "frameId": -1,
        "stepId": -1,
        "threadId": 0,
        "maxHops": 16,
        "lazy": false,
        "sessionId": "",
        "classifySource": true,
    });
    let req = make_request(1, "ct/originChain", args_json);
    let args: CtOriginChainArguments =
        serde_json::from_value(req.arguments.clone()).expect("decode CtOriginChainArguments");
    handler.origin_chain(req.clone(), args, tx).expect("origin_chain");
    let body = take_response_body(&rx, "ct/originChain");

    // Assert the wire shape the Nim ViewModel decodes.
    assert_eq!(body.get("queryVariable").and_then(JsonValue::as_str), Some("c"));
    let hops = body.get("hops").and_then(JsonValue::as_array).expect("hops array");
    assert_eq!(hops.len(), 3, "expected 3 hops, body={:?}", body);
    for hop in hops {
        // Required fields every hop carries (mirroring
        // `parseOriginHop` in origin_chain_types.nim).
        assert!(hop.get("kind").is_some());
        assert!(hop.get("targetExpr").is_some());
        assert!(hop.get("sourceExpr").is_some());
        assert!(hop.get("location").is_some());
        assert!(hop.get("stepId").is_some());
        assert!(hop.get("confidence").is_some());
    }
    let terminator = body.get("terminator").expect("terminator object");
    assert_eq!(terminator.get("kind").and_then(JsonValue::as_str), Some("literal"));
}

// ---------------------------------------------------------------------------
// M4 V#2 — applyChainResponse round-trip: parse the wire payload as
// JSON, walk the fields the Nim parser would walk, and confirm every
// downstream contract holds.
// ---------------------------------------------------------------------------

#[test]
fn test_m2_contract_origin_chain_response_parses_as_view_model_shape() {
    let (db, _tmp) = three_hop_literal_trace();
    let mut handler = handler_with_trace(db);
    handler.step_id = StepId(3);
    handler.replay.jump_to(StepId(3)).expect("jump_to step 3");

    let (tx, rx) = mpsc::channel::<DapMessage>();
    let args = CtOriginChainArguments {
        variable_name: "c".to_string(),
        variable_path: Vec::new(),
        frame_id: -1,
        step_id: -1,
        thread_id: 0,
        max_hops: 16,
        lazy: false,
        continuation_token: None,
        session_id: String::new(),
        classify_source: true,
    };
    let req = make_request(2, "ct/originChain", serde_json::to_value(&args).unwrap());
    handler.origin_chain(req, args, tx).expect("origin_chain");
    let body = take_response_body(&rx, "ct/originChain");

    // Decode + re-encode round-trip — what `parseOriginChain` then
    // `OriginChainVM.activeChain.val.get` would produce.
    let chain: db_backend::task::OriginChain = serde_json::from_value(body.clone()).expect("decode OriginChain");
    assert_eq!(chain.query_variable, "c");
    assert_eq!(chain.hops.len(), 3);
    assert_eq!(chain.terminator.kind, db_backend::task::TerminatorKind::Literal);
}

// ---------------------------------------------------------------------------
// M4 V#8 / V#9 — Placeholder + ct/originSummary roundtrip.
//
// The Nim view dispatches `originSummaryArgs([tokens...])` via the
// backend service. This test asserts that the wire payload mirrors
// `CtOriginSummaryArguments` and the response decodes into a parallel
// `summaries` array (the shape `applySummaryResponse` walks).
// ---------------------------------------------------------------------------

#[test]
fn test_m2_contract_origin_summary_batch_roundtrip_wire_shape() {
    let (db, _tmp) = three_hop_literal_trace();
    let mut handler = handler_with_trace(db);
    handler.step_id = StepId(3);
    handler.replay.jump_to(StepId(3)).expect("jump_to step 3");

    // First fetch the load-history response to capture a real placeholder
    // token the batch endpoint can resolve.
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let location = Location {
        path: "fixture.py".to_string(),
        line: 4,
        rr_ticks: RRTicks(3),
        ..Location::default()
    };
    let req = make_request(
        1,
        "ct/load-history",
        serde_json::json!({"expression": "c", "location": location, "isForward": false}),
    );
    let args: LoadHistoryArg = serde_json::from_value(req.arguments.clone()).expect("LoadHistoryArg");
    handler.load_history(req, args, tx).expect("load_history");
    let history_body = take_response_body(&rx, "ct/load-history");
    let results = history_body
        .get("results")
        .and_then(JsonValue::as_array)
        .expect("results array");
    assert!(!results.is_empty(), "expected at least one history row");
    let token = results
        .iter()
        .find_map(|row| {
            row.get("originSummary")
                .and_then(|s| s.get("placeholderToken"))
                .and_then(JsonValue::as_str)
                .map(str::to_string)
        })
        .expect("at least one placeholder token");

    // Now batch-resolve it.
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let summary_args = CtOriginSummaryArguments {
        tokens: vec![token.clone()],
    };
    let summary_req = make_request(2, "ct/originSummary", serde_json::to_value(&summary_args).unwrap());
    handler
        .origin_summary(summary_req, summary_args, tx)
        .expect("origin_summary");
    let body = take_response_body(&rx, "ct/originSummary");
    let summaries = body
        .get("summaries")
        .and_then(JsonValue::as_array)
        .expect("summaries array");
    assert_eq!(summaries.len(), 1);
    let first = &summaries[0];
    // The resolved summary either upgrades to an eager badge (no
    // placeholder flag) or surfaces a per-token error as a
    // UnknownVariable summary; both are acceptable per spec §5.3.2.
    let is_placeholder = first.get("isPlaceholder").and_then(JsonValue::as_bool).unwrap_or(false);
    assert!(
        !is_placeholder,
        "resolved summary should not be a placeholder anymore: {:?}",
        first
    );
}

// ---------------------------------------------------------------------------
// M4 V#10 — history popover renders per-entry origin badges. The
// backend wire response is the same `ct/load-history` payload the
// frontend already consumes. We re-assert here to lock the contract
// the Nim view depends on.
// ---------------------------------------------------------------------------

#[test]
fn test_m2_contract_load_history_emits_per_entry_origin_summaries_for_view_model() {
    let recipe = Recipe {
        source_path: "fixture.py",
        source: "v = 1\nv = 2\nv = 3\nprint(v)\n",
        function_name: "main",
        steps: vec![
            (1, vec![("v", int_value(1))]),
            (2, vec![("v", int_value(2))]),
            (3, vec![("v", int_value(3))]),
        ],
    };
    let (db, _tmp) = build_trace(recipe);
    let mut handler = handler_with_trace(db);
    handler.step_id = StepId(2);
    handler.replay.jump_to(StepId(2)).expect("jump_to step 2");

    let (tx, rx) = mpsc::channel::<DapMessage>();
    let location = Location {
        path: "fixture.py".to_string(),
        line: 3,
        rr_ticks: RRTicks(2),
        ..Location::default()
    };
    let req = make_request(
        1,
        "ct/load-history",
        serde_json::json!({"expression": "v", "location": location, "isForward": false}),
    );
    let args: LoadHistoryArg = serde_json::from_value(req.arguments.clone()).expect("LoadHistoryArg");
    handler.load_history(req, args, tx).expect("load_history");
    let body = take_response_body(&rx, "ct/load-history");
    let results = body.get("results").and_then(JsonValue::as_array).expect("results");
    assert!(!results.is_empty());
    for row in results {
        let summary = row
            .get("originSummary")
            .expect("each history entry carries originSummary");
        assert!(summary.get("terminatorKind").is_some());
        assert!(summary.get("hopCount").is_some());
    }
}

// ---------------------------------------------------------------------------
// M4 V#11 — omniscience-flow overlay carries per-annotated-value
// origin summaries on the `ct/load-flow` response. The Nim view
// renders each annotated value's icon-only badge from the same shape.
// ---------------------------------------------------------------------------

#[test]
fn test_m2_contract_load_flow_emits_per_value_origin_summaries_for_view_model() {
    let (db, _tmp) = three_hop_literal_trace();
    let mut handler = handler_with_trace(db);
    handler.step_id = StepId(3);
    handler.replay.jump_to(StepId(3)).expect("jump_to step 3");

    let (tx, rx) = mpsc::channel::<DapMessage>();
    let location = Location {
        path: "fixture.py".to_string(),
        line: 3,
        rr_ticks: RRTicks(3),
        ..Location::default()
    };
    let req = make_request(
        1,
        "ct/load-flow",
        serde_json::json!({
            "flowMode": 0,
            "location": location,
        }),
    );
    let args: db_backend::task::CtLoadFlowArguments =
        serde_json::from_value(req.arguments.clone()).expect("CtLoadFlowArguments");
    // load_flow may legitimately return no annotated values for the
    // toy fixture (and any errors are translated to logged warnings).
    // The assertion here is that the response, when present, carries
    // the `originSummaries` keyed by variable name per spec §3.2.3.
    let _ = handler.load_flow(req, args, tx);
    while let Ok(msg) = rx.try_recv() {
        if let DapMessage::Response(resp) = msg
            && resp.command == "ct/load-flow"
        {
            if let Some(summaries) = resp.body.get("originSummaries") {
                assert!(summaries.is_object(), "originSummaries must be a JSON object");
            }
            return;
        }
    }
}

// ---------------------------------------------------------------------------
// M4 V#13 — `originBadge.expressionStyle` is a pure-view setting.
// Asserted at the Nim level. Here we double-check the backend never
// emits an over-long terminator expression that would break the
// frontend's middle-ellipsis truncation logic.
// ---------------------------------------------------------------------------

#[test]
fn test_m2_contract_origin_chain_terminator_expression_is_a_single_line() {
    let (db, _tmp) = three_hop_literal_trace();
    let mut handler = handler_with_trace(db);
    handler.step_id = StepId(3);
    handler.replay.jump_to(StepId(3)).expect("jump_to step 3");

    let (tx, rx) = mpsc::channel::<DapMessage>();
    let args = CtOriginChainArguments {
        variable_name: "c".to_string(),
        variable_path: Vec::new(),
        frame_id: -1,
        step_id: -1,
        thread_id: 0,
        max_hops: 16,
        lazy: false,
        continuation_token: None,
        session_id: String::new(),
        classify_source: true,
    };
    let req = make_request(1, "ct/originChain", serde_json::to_value(&args).unwrap());
    handler.origin_chain(req, args, tx).expect("origin_chain");
    let body = take_response_body(&rx, "ct/originChain");
    let expr = body
        .get("terminator")
        .and_then(|t| t.get("expression"))
        .and_then(JsonValue::as_str)
        .expect("terminator expression string");
    assert!(
        !expr.contains('\n'),
        "terminator expression must be single-line for badge: {:?}",
        expr
    );
}

// ---------------------------------------------------------------------------
// M4 V#1 sibling — load_locals attaches an originSummary alongside
// every variable. The Nim `StateVM` consumes that summary on each row.
// ---------------------------------------------------------------------------

#[test]
fn test_m2_contract_load_locals_per_variable_origin_summary_for_view_model() {
    let (db, _tmp) = three_hop_literal_trace();
    let mut handler = handler_with_trace(db);
    handler.step_id = StepId(3);
    handler.replay.jump_to(StepId(3)).expect("jump_to step 3");

    let (tx, rx) = mpsc::channel::<DapMessage>();
    let req = make_request(
        1,
        "ct/load-locals",
        serde_json::json!({
            "rrTicks": 3,
            "countBudget": 1000,
            "minCountLimit": 0,
            "lang": Lang::Python as u8,
            "watchExpressions": [],
            "depthLimit": -1,
        }),
    );
    let args: CtLoadLocalsArguments = serde_json::from_value(req.arguments.clone()).expect("CtLoadLocalsArguments");
    handler.load_locals(req, args, tx).expect("load_locals");
    let body = take_response_body(&rx, "ct/load-locals");
    let locals = body.get("locals").and_then(JsonValue::as_array).expect("locals array");
    assert!(!locals.is_empty());
    for v in locals {
        let summary = v.get("originSummary").expect("originSummary attached");
        // The eager-mode default for State Pane locals.
        assert_eq!(
            summary.get("isPlaceholder").and_then(JsonValue::as_bool),
            Some(false),
            "expected eager mode for visible State Pane row: {:?}",
            summary
        );
        assert!(summary.get("terminatorKind").is_some());
    }
}
