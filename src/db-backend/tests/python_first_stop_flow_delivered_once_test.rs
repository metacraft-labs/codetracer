//! The flow at the first stop of a Python program is delivered once, and it
//! does not carry the module's globals.
//!
//! Issue: codetracer-pm
//! `issues/2026-11-04-python-first-stop-load-flow-returns-14-mb-twice-and-stalls-the-vscode-extension-host.md`.
//! At the first stop of `py_sudoku_solver` (the `<__main__>` frame, line 1),
//! `ct/load-flow` answered with 14.7 MB, and answered twice: once as the
//! `ct/updated-flow` event and once as the body of the `ct/load-flow`
//! response. The VS Code extension host decoded both copies and stalled every
//! other request behind them.
//!
//! Two defects made that payload:
//!
//! - **Doubled delivery.** `Handler::load_flow` sent the `FlowUpdate` on the
//!   event and again in the response. The flow is the event's
//!   (CodeTracer-DAP-Extensions.md, `ct/load-flow`); the response is an
//!   acknowledgement naming the event.
//! - **Every global on every name-less module line.** A Python line the name
//!   extractor found no names on (a docstring, an import, a `def` header)
//!   fell through to the flow walker's fallback for grammars that yield no
//!   names, which loads every local of the frame with no depth limit. A module
//!   frame's locals are its globals, `__builtins__` — the whole builtins
//!   module — among them: 15.2 MB of the 16.7 MB of step values.
//!
//! No mocks: the program is recorded by the real Python recorder, opened
//! through the production `CTFSTraceReader::open` + `Handler` path, moved with
//! `ct/goto-ticks` and asked for its flow with `ct/load-flow`, exactly the
//! requests a front-end sends at a stop.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

mod test_harness;

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::mpsc;

use codetracer_trace_types::StepId;
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::dap::{DapMessage, ProtocolMessage, Request};
use db_backend::dap_handler::Handler;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::task::{CtLoadFlowArguments, FlowMode, GoToTicksArguments, Location, TraceKind};
use db_backend::trace_reader::TraceReader;
use test_harness::{Language, TestRecording};

const TEST_NAME: &str = "python_first_stop_flow_is_delivered_once_without_the_module_globals";

/// The frame the recorder names a module's top level.
const MODULE_FRAME: &str = "<__main__>";

/// An upper bound on the serialized `ct/updated-flow` body. With both defects
/// fixed, the first-stop `ct/updated-flow` of `py_sudoku_solver` is a
/// 76 920-byte DAP message (measured 2026-11-05 against the replay-server
/// built from codetracer `4ef14d0d9` plus this change, over stdio); before,
/// it was 14 719 336 bytes, sent twice. The bound leaves room for the flow to
/// grow (more annotations per step) without admitting anything like a copy of
/// the module's globals.
const MAX_FLOW_EVENT_BYTES: usize = 2 * 1024 * 1024;

fn request(command: &str, arguments: serde_json::Value) -> Request {
    Request {
        base: ProtocolMessage {
            seq: 1,
            type_: "request".to_string(),
        },
        command: command.to_string(),
        arguments,
    }
}

/// The single `.ct` container the Python recorder wrote into `trace_dir`.
fn recorded_container(trace_dir: &Path) -> PathBuf {
    let containers: Vec<PathBuf> = std::fs::read_dir(trace_dir)
        .expect("read the trace dir")
        .map(|entry| entry.expect("trace dir entry").path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "ct"))
        .collect();
    assert_eq!(
        containers.len(),
        1,
        "expected exactly one .ct container in {}, found {containers:?}",
        trace_dir.display()
    );
    containers.into_iter().next().unwrap()
}

/// The first step in the module frame, which is where a front-end stops first
/// (the launch's `ct/complete-move` names it; step 0 is the recorder's
/// `<toplevel>` pseudo-frame).
fn first_module_step(reader: &dyn TraceReader) -> StepId {
    let in_module = |step_id: StepId| {
        reader
            .step(step_id)
            .and_then(|step| reader.call(step.call_key))
            .and_then(|call| reader.function(call.function_id))
            .is_some_and(|function| function.name == MODULE_FRAME)
    };
    (0..reader.step_count() as i64)
        .map(StepId)
        .find(|step_id| in_module(*step_id))
        .expect("the recording has a step in the module frame")
}

/// Move with `ct/goto-ticks` and return the location `ct/complete-move` carried.
fn move_to(handler: &mut Handler, step_id: StepId) -> Location {
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let args = GoToTicksArguments {
        thread_id: 0,
        ticks: step_id.0,
    };
    handler
        .goto_ticks(request("ct/goto-ticks", serde_json::to_value(&args).unwrap()), args, tx)
        .expect("ct/goto-ticks succeeds");
    for message in rx.try_iter() {
        if let DapMessage::Event(event) = message
            && event.event == "ct/complete-move"
        {
            return serde_json::from_value(event.body["location"].clone()).expect("the move's location decodes");
        }
    }
    panic!("ct/goto-ticks emitted no ct/complete-move");
}

/// Everything `ct/load-flow` sent, in order.
fn load_flow(handler: &mut Handler, location: Location) -> Vec<DapMessage> {
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let args = CtLoadFlowArguments {
        flow_mode: FlowMode::Call,
        location,
    };
    let arguments = serde_json::json!({ "flowMode": 0, "location": args.location });
    handler
        .load_flow(request("ct/load-flow", arguments), args, tx)
        .expect("ct/load-flow succeeds");
    rx.try_iter().collect()
}

fn carries_flow(body: &serde_json::Value) -> bool {
    body.get("viewUpdates").is_some()
}

#[test]
fn python_first_stop_flow_is_delivered_once_without_the_module_globals() {
    if test_harness::find_python_recorder().is_none() {
        test_harness::skip_or_fail_missing_prerequisite(
            TEST_NAME,
            "the Python recorder is not installed",
            "run inside the codetracer dev shell with the codetracer-python-recorder sibling checked out, or set CODETRACER_PYTHON_RECORDER_PATH",
        );
        return;
    }
    let Some((_python, version_label)) = test_harness::find_suitable_python() else {
        test_harness::skip_or_fail_missing_prerequisite(
            TEST_NAME,
            "no Python 3.10+ interpreter for the recorder",
            "put a Python 3.10+ interpreter on PATH (the codetracer dev shell provides one)",
        );
        return;
    };

    // The program the issue was measured on (the VS Code extension records it
    // as its `python-sudoku` fixture).
    let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../test-programs/py_sudoku_solver/main.py");
    let recording = TestRecording::create_db_trace_with_format(&source, Language::Python, &version_label, "ctfs")
        .expect("recording py_sudoku_solver/main.py succeeds");
    let container = recorded_container(&recording.trace_dir);
    let reader: Arc<dyn TraceReader> =
        Arc::new(CTFSTraceReader::open(&container).unwrap_or_else(|e| panic!("open {}: {e}", container.display())));

    let mut handler = Handler::construct_with_reader(
        TraceKind::Materialized,
        RecreatorArgs::default(),
        Arc::clone(&reader),
        false,
    );
    handler.set_trace_folder(&recording.trace_dir);
    handler.load_source_views(&recording.trace_dir);
    handler.load_bundled_sources(&recording.trace_dir);
    handler.initialized = true;

    let location = move_to(&mut handler, first_module_step(&*reader));
    assert_eq!(
        location.function_name, MODULE_FRAME,
        "the first stop must be in the module frame: {location:?}"
    );

    let messages = load_flow(&mut handler, location);

    // Delivered once: on the event, and the response acknowledges it.
    let events: Vec<&serde_json::Value> = messages
        .iter()
        .filter_map(|message| match message {
            DapMessage::Event(event) if event.event == "ct/updated-flow" => Some(&event.body),
            _ => None,
        })
        .collect();
    assert_eq!(events.len(), 1, "ct/load-flow must emit exactly one ct/updated-flow");
    let flow = events[0];
    assert!(carries_flow(flow), "the ct/updated-flow event carries the flow");
    let response = messages
        .iter()
        .find_map(|message| match message {
            DapMessage::Response(response) if response.command == "ct/load-flow" => Some(response),
            _ => None,
        })
        .expect("ct/load-flow is answered");
    assert!(response.success, "ct/load-flow succeeds: {:?}", response.message);
    // The acknowledgement names the event rather than being empty: a
    // body-only transport resolves a refusal with an empty body.
    assert_eq!(
        response.body,
        serde_json::json!({ "event": "ct/updated-flow" }),
        "the ct/load-flow response is the acknowledgement naming the event"
    );
    let copies = messages
        .iter()
        .filter(|message| match message {
            DapMessage::Event(event) => carries_flow(&event.body),
            DapMessage::Response(response) => carries_flow(&response.body),
            _ => false,
        })
        .count();
    assert_eq!(
        copies,
        1,
        "the flow must be delivered once; the ct/load-flow response is an acknowledgement, \
         and its body was {} bytes",
        response.body.to_string().len()
    );

    // No step of the module's flow copies the module's globals.
    let steps: Vec<&serde_json::Value> = flow["viewUpdates"]
        .as_array()
        .expect("viewUpdates is an array")
        .iter()
        .flat_map(|view| view["steps"].as_array().expect("a view's steps").iter())
        .collect();
    assert!(!steps.is_empty(), "the module's flow has steps");
    for step in &steps {
        for values in ["beforeValues", "afterValues"] {
            assert!(
                step[values].get("__builtins__").is_none(),
                "the step at line {} carries `__builtins__` in its {values}: a line that names no \
                 variable must not fall back to the module frame's globals",
                step["position"]
            );
        }
    }

    let event_bytes = flow.to_string().len();
    assert!(
        event_bytes <= MAX_FLOW_EVENT_BYTES,
        "the first-stop flow of py_sudoku_solver is {event_bytes} bytes, \
         more than the {MAX_FLOW_EVENT_BYTES} bound"
    );
}
