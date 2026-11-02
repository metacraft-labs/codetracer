//! The flow of a loop-heavy Python function parses its source file a bounded
//! number of times, not once per step it walks.
//!
//! Issue: codetracer-pm
//! `issues/2026-10-06-a-stop-inside-a-loop-heavy-python-function-takes-thirty-seconds.md`.
//! On a program whose `main` runs a 30-iteration loop of writes, every stop on
//! a line of `main` took 25–35 s to settle, while a stop in a small helper took
//! well under a second. The move itself was fast; the time went into the
//! `ct/load-flow` a front-end sends for the stop, because the flow walker
//! (`CallFlowPreloader`) handed `load_location` a fresh `ExprLoader` on every
//! step, and `load_location` re-read and tree-sitter-parsed the whole file
//! into it: two parses per walked step, ~2200 for a ~1100-step walk of `main`.
//! The Terminal Output pane's screen scrubber is real-time
//! (Terminal-Output-Pane.md §3) — a drag moves the debugger to each write it
//! crosses — so a cost per walked step of the stop's function makes it
//! unusable on exactly the programs it exists for.
//!
//! The assertion is on the parse COUNT rather than on wall-clock time, so the
//! test is deterministic on a loaded host: the walk must parse each file it
//! touches a constant number of times whatever the function's step count.
//! `expr_loader::tree_sitter_parses_on_this_thread` is the observable; the
//! request is served in-process, on this thread.
//!
//! No mocks: the program is recorded by the real Python recorder, opened
//! through the production `CTFSTraceReader::open` + `Handler` path, moved with
//! `ct/goto-ticks` and asked for its flow with `ct/load-flow`, exactly the
//! requests a front-end sends.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

mod test_harness;

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::mpsc;

use codetracer_trace_types::StepId;
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::dap::{DapMessage, ProtocolMessage, Request};
use db_backend::dap_handler::Handler;
use db_backend::expr_loader::tree_sitter_parses_on_this_thread;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::task::{CtLoadFlowArguments, FlowMode, FlowUpdate, GoToTicksArguments, Location, TraceKind};
use db_backend::trace_reader::TraceReader;
use test_harness::{Language, TestRecording};

const TEST_NAME: &str = "loop_heavy_python_flow_parses_its_file_a_bounded_number_of_times";

/// Fewer walked steps than this and the test would not be measuring a
/// loop-heavy function: the flow of `main` in the recording of
/// `loop_heavy_writes.py` walks about eight hundred steps (792 on 2026-10-20,
/// where the per-step loader parsed the file 1588 times).
const MIN_LOOP_HEAVY_STEPS: usize = 300;

/// Parses a flow load may cost, one per loader that sees the file: the
/// preloader's own loader (which keeps it for the session, so only the first
/// load pays it), the walk's loader, and the loader
/// `MaterializedReplaySession::jump_to_call` builds once to widen the window to
/// the call's entry. None of them depends on how many steps the walk visits.
const MAX_PARSES_PER_FLOW_LOAD: u64 = 3;

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

/// The step of the `index`th terminal write made from `main`.
fn write_step_in_main(reader: &dyn TraceReader, index: usize) -> StepId {
    let in_main = |step_id: StepId| {
        let step = reader.step(step_id).expect("an event's step exists");
        reader
            .call(step.call_key)
            .and_then(|call| reader.function(call.function_id))
            .is_some_and(|function| function.name == "main")
    };
    let steps: Vec<StepId> = reader
        .events()
        .iter()
        .map(|event| event.step_id)
        .filter(|step_id| in_main(*step_id))
        .collect();
    assert!(
        steps.len() > index,
        "the recording should hold more than {index} events made from main, found {}",
        steps.len()
    );
    steps[index]
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

/// Ask for the flow at `location` with `ct/load-flow` and decode `ct/updated-flow`.
fn load_flow(handler: &mut Handler, location: Location) -> FlowUpdate {
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let args = CtLoadFlowArguments {
        flow_mode: FlowMode::Call,
        location,
    };
    let arguments = serde_json::json!({ "flowMode": 0, "location": args.location });
    handler
        .load_flow(request("ct/load-flow", arguments), args, tx)
        .expect("ct/load-flow succeeds");
    for message in rx.try_iter() {
        if let DapMessage::Event(event) = message
            && event.event == "ct/updated-flow"
        {
            return serde_json::from_value(event.body).expect("the flow update decodes");
        }
    }
    panic!("ct/load-flow emitted no ct/updated-flow");
}

#[test]
fn loop_heavy_python_flow_parses_its_file_a_bounded_number_of_times() {
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

    let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/python/loop_heavy_writes.py");
    let recording = TestRecording::create_db_trace_with_format(&source, Language::Python, &version_label, "ctfs")
        .expect("recording loop_heavy_writes.py succeeds");
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

    // A write in the middle of the loop, as a scrubber drag reaches it.
    let target = write_step_in_main(&*reader, 10);
    let location = move_to(&mut handler, target);
    assert_eq!(
        location.function_name, "main",
        "the move must stop in main, the loop-heavy function: {location:?}"
    );

    let parses_before = tree_sitter_parses_on_this_thread();
    let flow = load_flow(&mut handler, location);
    let parses = tree_sitter_parses_on_this_thread() - parses_before;

    let walked_steps: usize = flow.view_updates.iter().map(|update| update.steps.len()).sum();
    assert!(
        walked_steps >= MIN_LOOP_HEAVY_STEPS,
        "the flow of main must be loop-heavy for this test to mean anything: \
         it walked {walked_steps} steps, expected at least {MIN_LOOP_HEAVY_STEPS}"
    );
    assert!(
        parses <= MAX_PARSES_PER_FLOW_LOAD,
        "ct/load-flow over a {walked_steps}-step walk of main parsed its source {parses} times; \
         a flow load must parse each file a bounded number of times (at most \
         {MAX_PARSES_PER_FLOW_LOAD}), not once per walked step"
    );
}
