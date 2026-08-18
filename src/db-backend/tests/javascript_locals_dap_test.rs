//! JavaScript locals: per-step values and point-in-time semantics
//! (issue #602, M37).
//!
//! # The two halves of #602
//!
//! Stopping inside a JavaScript frame used to show an empty (or wrong)
//! State panel. Two independent defects produced that symptom, and this
//! file guards one each:
//!
//! 1. **Recorder half** — the JS recorder emitted a value only on the
//!    step that *wrote* a binding, so stopping on a non-assigning line
//!    (`return scaled;`) reported nothing at all. It now emits the full
//!    in-scope local set on every step.
//!    Guarded by [`test_js_locals_live_recording_has_values_on_every_step`],
//!    which drives the real recorder end-to-end over DAP.
//!
//! 2. **db-backend half** — `Db::load_locals` special-cased JavaScript by
//!    re-scanning the frame from its entry step and unioning every value
//!    it saw into a `HashMap`, because a point-in-time read returned
//!    nothing. That union is last-write-wins, so it attributes values
//!    recorded on *other* steps to the step the user is stopped on, and
//!    keeps bindings alive after their scope has exited. The special case
//!    is gone; JS now takes the same single-step path as every other
//!    language.
//!    Guarded by [`test_js_load_locals_is_point_in_time_not_a_frame_union`].
//!
//! # Why the second test builds its trace by hand
//!
//! The union and a point-in-time read only disagree on a trace whose
//! steps carry *sparse* values — i.e. where a step records just the
//! binding that line wrote. That is exactly the shape every JavaScript
//! trace had before M37 (and the shape the committed
//! `examples/recordings/javascript/flow_test` fixture still has), and it
//! is the shape no current recorder produces. A live recording therefore
//! cannot distinguish the two implementations: with full per-step
//! snapshots the prefix-union happens to agree with the snapshot almost
//! everywhere.
//!
//! So the second test hand-builds a five-step trace in that sparse
//! shape. This is a **synthetic trace, not a mock object**: no behaviour
//! is stubbed out, and the real `Db`/`Handler`/`ct/load-locals` code path
//! runs over it exactly as it would over a recorded one. The only thing
//! standing in for a recorder is the trace *data*, via the same
//! `InMemoryTraceReader` escape hatch documented in `origin_dap_test.rs`.
//! It is justified because the contract under test — "answer for the step
//! the user is on, not for the frame's history" — is not observable on
//! any trace a current recorder emits, and because traces in that shape
//! are still out there and must not be answered with stale values.
//!
//! # A note on the recorder's step semantics
//!
//! The JS recorder's per-step snapshot reflects the state **after** the
//! step's line has run (the step for `const base = a + b;` already
//! carries `base`), whereas the Ruby recorder's reflects the state
//! **before** it. The live test below is deliberately written so it holds
//! under either convention: it asserts values that are identical in both.
//! Reconciling the two is a recorder-side question, out of scope here.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc;
use std::time::Duration;

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
use db_backend::task::{CtLoadLocalsArguments, TraceKind};
use serde_json::Value as JsonValue;
use tempfile::TempDir;

mod test_harness;
use test_harness::{DapStdioTestClient, FlowData, Language, TestRecording, find_js_recorder};

// ===========================================================================
// Part 1 — live recording over DAP
// ===========================================================================

/// 1-based line of `var offset = 10;` in the fixture.
const OFFSET_DECL_LINE: u32 = 19;
/// 1-based line of `return scaled;` in the fixture.
const RETURN_LINE: u32 = 21;

/// Require the JavaScript recorder, or fail loudly.
///
/// `codetracer-js-recorder` is a **required** sibling for these suites
/// (`ci/test/ct-providers.sh`), so its absence is an environment error,
/// not a reason to report success. Silently skipping is how the JS
/// locals tests stayed green for the entire lifetime of issue #602.
///
/// `CT_PROVIDERS_ALLOW_MISSING=1` is the documented escape hatch (see the
/// repo CLAUDE.md) for running the suite without the recorder siblings;
/// only then do we skip. Returns the Node version label used to name the
/// trace directory.
fn require_js_recorder() -> Option<String> {
    if find_js_recorder().is_none() {
        if std::env::var("CT_PROVIDERS_ALLOW_MISSING").is_ok() {
            eprintln!(
                "SKIPPED (CT_PROVIDERS_ALLOW_MISSING=1): JavaScript recorder not found; \
                 set CODETRACER_JS_RECORDER_PATH or build codetracer-js-recorder"
            );
            return None;
        }
        panic!(
            "codetracer-js-recorder not found — it is a REQUIRED sibling for this suite. \
             Set CODETRACER_JS_RECORDER_PATH, put codetracer-js-recorder on PATH, or set \
             CT_PROVIDERS_ALLOW_MISSING=1 to skip."
        );
    }
    Some(
        std::process::Command::new("node")
            .arg("--version")
            .output()
            .ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .map(|s| s.trim().to_string())
            .unwrap_or_else(|| "unknown".to_string()),
    )
}

/// Issue `ct/load-locals` at the debugger's current position and return
/// the locals as `name -> integer value`.
///
/// A local whose value did not load (`<NONE>`) or is not an integer fails
/// the test rather than being dropped: silently skipping it would let a
/// regression that empties every value masquerade as a merely missing
/// name — which is precisely how #602 hid for so long.
fn load_locals_as_ints(client: &mut DapStdioTestClient, context: &str) -> HashMap<String, i64> {
    // `rrTicks` is ignored by the db backend — `Db::load_locals` answers
    // for `self.step_id`, i.e. wherever the session is currently stopped.
    // The remaining fields mirror what the frontend sends.
    let req = client.dap_client_mut().request(
        "ct/load-locals",
        serde_json::json!({
            "rrTicks": 0,
            "countBudget": 1000,
            "minCountLimit": 0,
            "lang": 0,
            "watchExpressions": [],
            "depthLimit": -1,
        }),
    );
    client.send_message(&req).expect("failed to send ct/load-locals");
    let response = client
        .read_until_response_msg("ct/load-locals", Duration::from_secs(30))
        .expect("no ct/load-locals response");

    let body = match response {
        DapMessage::Response(r) => {
            assert!(r.success, "ct/load-locals failed at {}: {:?}", context, r.message);
            r.body
        }
        other => panic!("expected a response to ct/load-locals at {}, got {:?}", context, other),
    };

    let locals = body
        .get("locals")
        .and_then(|v| v.as_array())
        .unwrap_or_else(|| panic!("ct/load-locals response at {} has no locals array: {}", context, body))
        .clone();

    let mut out = HashMap::new();
    for local in &locals {
        let name = local
            .get("expression")
            .and_then(|v| v.as_str())
            .unwrap_or_else(|| panic!("local without an expression at {}: {}", context, local));
        let value = local.get("value").cloned().unwrap_or(JsonValue::Null);
        let int = FlowData::extract_int_value(&value).unwrap_or_else(|| {
            panic!(
                "local {:?} at {} has no loaded integer value (raw: {}) — the recorder must \
                 emit a value for every in-scope binding on every step",
                name, context, value
            )
        });
        out.insert(name.to_string(), int);
    }
    out
}

/// Assert the expected `name -> value` pairs are present, printing the
/// whole map on failure.
fn assert_locals(actual: &HashMap<String, i64>, expected: &[(&str, i64)], context: &str) {
    for (name, expected_value) in expected {
        let got = actual
            .get(*name)
            .unwrap_or_else(|| panic!("expected local {:?} at {} is missing; got {:?}", name, context, actual));
        assert_eq!(
            got, expected_value,
            "local {:?} at {}: expected {}, got {} (all locals: {:?})",
            name, context, expected_value, got, actual
        );
    }
}

/// Issue #602 end-to-end: every in-scope binding carries a value at every
/// step of a real JavaScript recording — including on a line that assigns
/// nothing.
#[test]
fn test_js_locals_live_recording_has_values_on_every_step() {
    let Some(version_label) = require_js_recorder() else {
        return;
    };

    let source_path =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/javascript/javascript_locals_test.js");
    assert!(
        source_path.exists(),
        "JavaScript locals fixture not found at {}",
        source_path.display()
    );

    let recording = TestRecording::create_db_trace(&source_path, Language::JavaScript, &version_label)
        .expect("JavaScript recording failed");

    let mut client = DapStdioTestClient::start().expect("failed to start the DAP stdio client");
    client
        .initialize_and_launch(&recording)
        .expect("failed to initialize the DAP session");

    // --- Stop 1: mid-frame, before the reassignment. ---------------------
    //
    // `scaled` is 84 here and only becomes 94 further down the frame.
    // Reporting 94 would mean the answer came from the frame's end state
    // rather than from this step — the class of bug the deleted JS
    // frame-union produced.
    client
        .set_breakpoint(&source_path, OFFSET_DECL_LINE)
        .expect("failed to set a breakpoint on the `var offset` line");
    let location = client
        .continue_to_breakpoint()
        .expect("failed to continue to the `var offset` line");
    assert_eq!(
        location.line, OFFSET_DECL_LINE as i64,
        "expected to stop on line {}, stopped at {}:{}",
        OFFSET_DECL_LINE, location.path, location.line
    );

    let mid_frame = load_locals_as_ints(&mut client, "the `var offset` line (19)");
    assert_locals(
        &mid_frame,
        &[("a", 10), ("b", 32), ("base", 42), ("scaled", 84)],
        "the `var offset` line (19)",
    );

    // --- Stop 2: the `return` line — the #602 reproduction. --------------
    //
    // No binding is written here. Before the recorder fix this step
    // carried no values at all and the State panel was empty. Every
    // in-scope binding must now be present with its current value.
    client
        .set_breakpoint(&source_path, RETURN_LINE)
        .expect("failed to set a breakpoint on the return line");
    let location = client
        .continue_to_breakpoint()
        .expect("failed to continue to the return line");
    assert_eq!(
        location.line, RETURN_LINE as i64,
        "expected to stop on the return line, stopped at {}:{}",
        location.path, location.line
    );

    let at_return = load_locals_as_ints(&mut client, "the return line (21)");
    assert_locals(
        &at_return,
        &[("a", 10), ("b", 32), ("base", 42), ("scaled", 94), ("offset", 10)],
        "the return line (21)",
    );
}

// ===========================================================================
// Part 2 — point-in-time contract on a sparse (pre-M37 shaped) JS trace
// ===========================================================================

/// Build a JavaScript trace whose steps carry only the value the line
/// wrote — the shape produced by every pre-M37 JS recorder.
///
/// The five steps mirror `test-programs/javascript/javascript_locals_test.js`:
///
/// | step | line | recorded |
/// |------|------|----------|
/// | 0    | 17   | `base = 42`   |
/// | 1    | 18   | `scaled = 84` |
/// | 2    | 19   | `offset = 10` |
/// | 3    | 20   | `scaled = 94` |
/// | 4    | 21   | *(nothing — `return scaled;` writes no binding)* |
///
/// The source path ends in `.js` because that is what the deleted
/// `is_javascript_frame` keyed the special case on.
fn sparse_javascript_trace() -> (Db, TempDir) {
    const SOURCE_PATH: &str = "main.js";
    const SOURCE: &str = "function compute(a, b) {\n  const base = a + b;\n  let scaled = base * 2;\n  \
                          var offset = 10;\n  scaled = scaled + offset;\n  return scaled;\n}\ncompute(10, 32);\n";
    // (line, [(name, value)]) — one write site per step, plus a final
    // non-assigning step.
    let steps: Vec<(i64, Vec<(&str, i64)>)> = vec![
        (17, vec![("base", 42)]),
        (18, vec![("scaled", 84)]),
        (19, vec![("offset", 10)]),
        (20, vec![("scaled", 94)]),
        (21, vec![]),
    ];

    let workdir_holder = tempfile::tempdir().expect("tempdir");
    let workdir = workdir_holder.path().to_path_buf();
    let abs_source = workdir.join(SOURCE_PATH);
    std::fs::write(&abs_source, SOURCE).expect("write source");

    let mut db = Db::new(&workdir);
    db.paths.push(String::new());
    db.paths.push(SOURCE_PATH.to_string());
    db.path_map.insert(SOURCE_PATH.to_string(), PathId(1));
    db.path_map.insert(abs_source.to_string_lossy().to_string(), PathId(1));

    db.types.push(TypeRecord {
        kind: TypeKind::Int,
        lang_type: "number".to_string(),
        specific_info: TypeSpecificInfo::None,
    });
    db.functions.push(FunctionRecord {
        path_id: PathId(1),
        line: TraceLine(16),
        name: "compute".to_string(),
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

    // A single frame for the whole trace: the union walked from
    // `call.step_id` to the current step, so every step must belong to
    // the same call for the two implementations to differ at all.
    let call_key = CallKey(0);
    db.calls.push(DbCall {
        key: call_key,
        function_id: FunctionId(0),
        args: Vec::new(),
        return_value: ValueRecord::None { type_id: TypeId(0) },
        step_id: StepId(0),
        depth: 0,
        parent_key: NO_KEY,
        children_keys: Vec::new(),
    });

    let mut step_map_for_path: HashMap<usize, Vec<DbStep>> = HashMap::new();
    for (step_idx, (line, writes)) in steps.iter().enumerate() {
        let step = DbStep {
            step_id: StepId(step_idx as i64),
            path_id: PathId(1),
            line: TraceLine(*line),
            column: None,
            call_key,
            global_call_key: call_key,
        };
        db.steps.push(step);
        step_map_for_path.entry(*line as usize).or_default().push(step);

        let mut var_records = Vec::new();
        for (name, value) in writes {
            let variable_id = ensure_var(&mut db, name);
            var_records.push(FullValueRecord {
                variable_id,
                value: ValueRecord::Int {
                    i: *value,
                    type_id: TypeId(0),
                },
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

/// Run `ct/load-locals` against `handler` at `step` and return the
/// resulting `name -> integer value` map.
fn load_locals_at(handler: &mut Handler, step: StepId) -> HashMap<String, i64> {
    handler.step_id = step;
    handler.replay.jump_to(step).expect("jump_to");

    let (tx, rx) = mpsc::channel::<DapMessage>();
    let arguments = serde_json::json!({
        "rrTicks": step.0,
        "countBudget": 1000,
        "minCountLimit": 0,
        "lang": Lang::Javascript as u8,
        "watchExpressions": [],
        "depthLimit": -1,
    });
    let req = Request {
        base: ProtocolMessage {
            seq: 1,
            type_: "request".to_string(),
        },
        command: "ct/load-locals".to_string(),
        arguments: arguments.clone(),
    };
    let args: CtLoadLocalsArguments = serde_json::from_value(arguments).expect("CtLoadLocalsArguments");
    handler.load_locals(req, args, tx).expect("load_locals");

    let mut body = None;
    while let Ok(msg) = rx.try_recv() {
        if let DapMessage::Response(resp) = msg
            && resp.command == "ct/load-locals"
        {
            assert!(resp.success, "ct/load-locals failed: {:?}", resp.message);
            body = Some(resp.body);
        }
    }
    let body = body.expect("no ct/load-locals response on the channel");

    body.get("locals")
        .and_then(JsonValue::as_array)
        .expect("locals array")
        .iter()
        .map(|local| {
            let name = local
                .get("expression")
                .and_then(JsonValue::as_str)
                .expect("local expression")
                .to_string();
            let value = local.get("value").cloned().unwrap_or(JsonValue::Null);
            let int = FlowData::extract_int_value(&value)
                .unwrap_or_else(|| panic!("local {:?} has no integer value: {}", name, value));
            (name, int)
        })
        .collect()
}

/// `ct/load-locals` answers for the step the user is stopped on — never
/// for the frame's history.
///
/// The deleted JavaScript special case unioned every value recorded
/// between the frame's entry step and the current one into a
/// last-write-wins `HashMap`. On the sparse trace built above that means
/// step 3 (`scaled = scaled + offset;`) reported `base` and `offset`
/// recorded on *earlier* lines alongside `scaled`. Those extra rows are
/// not free: the same mechanism keeps a block-scoped `let` or a loop
/// binder on screen after its scope has exited, and pins a value that was
/// only ever true at some other point in the frame.
///
/// Completeness is the recorder's job — it must write every in-scope
/// binding on every step, which since M37 it does. The db-backend's job
/// is to report exactly what the step recorded.
#[test]
fn test_js_load_locals_is_point_in_time_not_a_frame_union() {
    let (db, _tmp) = sparse_javascript_trace();
    let mut handler = handler_with_trace(db);

    // Step 3 is the reassignment. Its own record is `scaled = 94`, and
    // that is the entire correct answer for this trace.
    let at_reassignment = load_locals_at(&mut handler, StepId(3));
    assert_eq!(
        at_reassignment.get("scaled"),
        Some(&94),
        "the step's own recorded value must be reported: {:?}",
        at_reassignment
    );
    let names: HashSet<&str> = at_reassignment.keys().map(String::as_str).collect();
    assert_eq!(
        names,
        HashSet::from(["scaled"]),
        "locals at step 3 must come from step 3 alone; `base`/`offset` here mean the \
         frame-history union is back: {:?}",
        at_reassignment
    );

    // Step 1 declares `scaled = 84`. Reading it back must not be
    // contaminated by the later reassignment either — a point-in-time
    // read is point-in-time in both directions.
    let at_declaration = load_locals_at(&mut handler, StepId(1));
    assert_eq!(
        at_declaration.get("scaled"),
        Some(&84),
        "step 1 must report the value recorded at step 1: {:?}",
        at_declaration
    );

    // Step 4 (`return scaled;`) records nothing in this pre-M37 shape, so
    // there is nothing to report. Answering with the frame's accumulated
    // state here is what the deleted workaround did; it is the compat
    // cost of dropping it, and it is correct — the trace genuinely does
    // not carry that data, and traces recorded since M37 do.
    let at_return = load_locals_at(&mut handler, StepId(4));
    assert!(
        at_return.is_empty(),
        "a step that recorded no values must report none, not the frame's history: {:?}",
        at_return
    );
}
