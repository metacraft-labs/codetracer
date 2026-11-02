//! `ct/load-terminal` answers the same whichever request came before it.
//!
//! Spec reference: codetracer-specs
//! `spec/Architecture/CodeTracer-DAP-Extensions.md`, `ct/load-terminal`: the
//! terminal's writes are the event log's standard-output and standard-error
//! writes, with the same positions and the same `stdout` flag (false for a
//! write to standard error), and a live session keeps its terminal in step
//! with its event log. `spec/Trace-Files/MCR-Event-Log-Stream.md` §2.3
//! separates `Write` (standard output) from `WriteStderr`.
//!
//! ## What this pins
//!
//! 1. A materialized trace with a write to standard output and one to
//!    standard error answers `ct/load-terminal` and `ct/load-terminal-lines`
//!    identically whether `ct/event-load` came first or not, with
//!    `stdout: false` on the standard-error write, and `ct/event-load`
//!    labels that write the same way.
//! 2. A live recreator session whose event log grows after the first
//!    terminal request shows the later output in `ct/load-terminal` and
//!    `ct/load-terminal-lines`, as `ct/event-load` does.
//!
//! ## Why a test double stands in for the replay session (case 2 only)
//!
//! [`GrowingEventLog`] replaces a live session's `ReplaySession` and answers
//! only `load_events`, from a list the test extends between requests. The
//! production answer comes from a replay worker recording a running program
//! (`ct-native-replay` from the sibling `codetracer-native-backend` repo, or
//! the MCR worker), and the moment the program writes more output is not
//! something a test can schedule against a real process. The handler half —
//! which caches it keeps and when it drops them — is what this pins, so the
//! double supplies the worker's growing list and nothing else; every other
//! trait method is unreachable here and panics if called. Case 1 uses no
//! double: it runs a real materialized trace through the trace processor.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::error::Error;
use std::path::PathBuf;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};

use codetracer_trace_types::{
    CallRecord, EventLogKind, FunctionId, FunctionRecord, Line, PathId, RecordEvent, StepId, StepRecord,
    TraceLowLevelEvent, TypeKind, TypeRecord, TypeSpecificInfo,
};
use db_backend::dap::{self, DapMessage};
use db_backend::dap_handler::Handler;
use db_backend::db::{Db, DbRecordEvent};
use db_backend::expr_loader::ExprLoader;
use db_backend::in_memory_trace_reader::InMemoryTraceReader;
use db_backend::lang::Lang;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::replay::ReplaySession;
use db_backend::task::{
    Action, Breakpoint, CallLine, CtLoadLocalsArguments, Events, HistoryResultWithRecord, LoadHistoryArg, Location,
    ProgramEvent, TraceKind, VariableWithRecord,
};
use db_backend::trace_processor::TraceProcessor;
use db_backend::value::ValueRecordWithType;
use serde_json::{Value, json};

/// Send one request through `call` and return the body of its response.
fn request(
    command: &str,
    arguments: Value,
    call: impl FnOnce(dap::Request, mpsc::Sender<DapMessage>) -> Result<(), Box<dyn Error>>,
) -> Value {
    let (sender, receiver) = mpsc::channel();
    let req = dap::Request {
        base: dap::ProtocolMessage {
            seq: 1,
            type_: "request".to_string(),
        },
        command: command.to_string(),
        arguments,
    };
    call(req, sender).unwrap_or_else(|e| panic!("{command} failed: {e}"));
    let response = receiver
        .try_iter()
        .find_map(|message| match message {
            DapMessage::Response(response) => Some(response),
            _ => None,
        })
        .unwrap_or_else(|| panic!("{command} sent no response"));
    assert!(response.success, "{command} answered a failure: {response:?}");
    response.body
}

fn load_terminal(handler: &mut Handler) -> Value {
    request("ct/load-terminal", json!({}), |r, s| handler.load_terminal(r, s))
}

fn load_terminal_lines(handler: &mut Handler) -> Value {
    request("ct/load-terminal-lines", json!({ "start": 0, "count": 100 }), |r, s| {
        handler.load_terminal_lines(r, s)
    })
}

fn event_load(handler: &mut Handler) -> Value {
    request("ct/event-load", json!({ "start": 0, "count": 100 }), |r, s| {
        handler.event_load(r, s)
    })
}

/// A materialized trace of three steps that writes `out\n` to standard output
/// at the first and `err\n` to standard error at the second.
fn trace_with_a_stderr_write() -> Db {
    let workdir = PathBuf::from("/test/workdir");
    let step = |line| {
        TraceLowLevelEvent::Step(StepRecord {
            path_id: PathId(0),
            line: Line(line),
        })
    };
    let write = |kind, content: &str| {
        TraceLowLevelEvent::Event(RecordEvent {
            kind,
            metadata: String::new(),
            content: content.to_string(),
        })
    };
    let trace = vec![
        TraceLowLevelEvent::Path(workdir.join("main.py")),
        TraceLowLevelEvent::Function(FunctionRecord {
            path_id: PathId(0),
            line: Line(1),
            name: "<top-level>".to_string(),
        }),
        TraceLowLevelEvent::Call(CallRecord {
            function_id: FunctionId(0),
            args: vec![],
        }),
        TraceLowLevelEvent::Type(TypeRecord {
            kind: TypeKind::None,
            lang_type: "None".to_string(),
            specific_info: TypeSpecificInfo::None,
        }),
        step(1),
        write(EventLogKind::Write, "out\n"),
        step(2),
        write(EventLogKind::WriteStderr, "err\n"),
        step(3),
    ];
    let mut db = Db::new(&workdir);
    TraceProcessor::new(&mut db)
        .postprocess(&trace)
        .expect("the fixture trace processes");
    db
}

fn materialized_handler() -> Handler {
    Handler::new(
        TraceKind::Materialized,
        RecreatorArgs::default(),
        Box::new(trace_with_a_stderr_write()),
    )
}

/// The `(content, stdout)` of each row, for the assertion messages.
fn rows(events: &Value) -> Vec<(String, bool)> {
    events
        .as_array()
        .expect("an array of events")
        .iter()
        .map(|e| {
            (
                e["content"].as_str().unwrap_or_default().to_string(),
                e["stdout"].as_bool().expect("every row carries stdout"),
            )
        })
        .collect()
}

#[test]
fn a_materialized_stderr_write_is_not_stdout_whichever_request_came_first() {
    // Terminal first: built by the handler's scan of the trace's events.
    let mut terminal_first = materialized_handler();
    let terminal_a = load_terminal(&mut terminal_first);
    let lines_a = load_terminal_lines(&mut terminal_first);

    // Event log first: the terminal is cut from the event log's list.
    let mut events_first = materialized_handler();
    let event_log = event_load(&mut events_first);
    let terminal_b = load_terminal(&mut events_first);
    let lines_b = load_terminal_lines(&mut events_first);

    let expected = vec![("out\n".to_string(), true), ("err\n".to_string(), false)];
    assert_eq!(rows(&terminal_a), expected, "terminal before ct/event-load");
    assert_eq!(rows(&terminal_b), expected, "terminal after ct/event-load");
    // The whole rows, positions and ticks included, not only the flag.
    assert_eq!(terminal_a, terminal_b, "the terminal depends on the request order");
    assert_eq!(lines_a, lines_b, "the terminal lines depend on the request order");

    // The event log labels the write the same way: its stderr write is not
    // standard output either.
    assert_eq!(
        rows(&event_log["events"]),
        expected,
        "ct/event-load labels a stderr write as standard output"
    );
    // And the terminal's rows are the event log's rows.
    assert_eq!(terminal_b, event_log["events"]);

    let segment_stdout: Vec<bool> = lines_a["lines"]
        .as_array()
        .expect("lines")
        .iter()
        .flat_map(|line| line["segments"].as_array().cloned().unwrap_or_default())
        .map(|segment| segment["stdout"].as_bool().expect("segment stdout"))
        .collect();
    assert_eq!(segment_stdout, vec![true, false], "ct/load-terminal-lines: {lines_a}");
}

/// A live session's replay worker, reduced to its event list. See the module
/// documentation for why it is a double.
#[derive(Debug)]
struct GrowingEventLog {
    events: Arc<Mutex<Vec<ProgramEvent>>>,
}

const ONLY_LOAD_EVENTS: &str = "GrowingEventLog answers load_events only";

fn write_event(index: usize, content: &str) -> ProgramEvent {
    ProgramEvent {
        kind: EventLogKind::Write,
        content: content.to_string(),
        bytes: content.len(),
        rr_event_id: index,
        event_index: index,
        direct_location_rr_ticks: index as i64 + 1,
        stdout: true,
        high_level_path: "/test/workdir/main.c".to_string(),
        high_level_line: index as i64 + 1,
        ..ProgramEvent::default()
    }
}

impl ReplaySession for GrowingEventLog {
    fn load_events(&mut self) -> Result<Events, Box<dyn Error>> {
        let events = self.events.lock().expect("event list").clone();
        Ok(Events {
            first_events: events.iter().take(20).cloned().collect(),
            contents: String::new(),
            events,
        })
    }

    fn load_location(&mut self, _expr_loader: &mut ExprLoader) -> Result<Location, Box<dyn Error>> {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn run_to_entry(&mut self) -> Result<(), Box<dyn Error>> {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn step(&mut self, _action: Action, _forward: bool) -> Result<bool, Box<dyn Error>> {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn load_locals(&mut self, _arg: CtLoadLocalsArguments) -> Result<Vec<VariableWithRecord>, Box<dyn Error>> {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn load_value(
        &mut self,
        _expression: &str,
        _depth_limit: Option<usize>,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn load_return_value(
        &mut self,
        _depth_limit: Option<usize>,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn load_step_events(&mut self, _step_id: StepId, _exact: bool) -> Vec<DbRecordEvent> {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn load_callstack(&mut self) -> Result<Vec<CallLine>, Box<dyn Error>> {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn load_history(&mut self, _arg: &LoadHistoryArg) -> Result<(Vec<HistoryResultWithRecord>, i64), Box<dyn Error>> {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn add_breakpoint(
        &mut self,
        _path: &str,
        _line: i64,
        _column: Option<i64>,
        _condition: Option<String>,
    ) -> Result<Breakpoint, Box<dyn Error>> {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn delete_breakpoint(&mut self, _breakpoint: &Breakpoint) -> Result<bool, Box<dyn Error>> {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn delete_breakpoints(&mut self) -> Result<bool, Box<dyn Error>> {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn toggle_breakpoint(&mut self, _breakpoint: &Breakpoint) -> Result<Breakpoint, Box<dyn Error>> {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn enable_breakpoints(&mut self) -> Result<(), Box<dyn Error>> {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn disable_breakpoints(&mut self) -> Result<(), Box<dyn Error>> {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn jump_to(&mut self, _step_id: StepId) -> Result<bool, Box<dyn Error>> {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn jump_to_call(&mut self, _location: &Location) -> Result<Location, Box<dyn Error>> {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn event_jump(&mut self, _event: &ProgramEvent) -> Result<bool, Box<dyn Error>> {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn callstack_jump(&mut self, _depth: usize) -> Result<(), Box<dyn Error>> {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn location_jump(&mut self, _location: &Location) -> Result<(), Box<dyn Error>> {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn tracepoint_jump(&mut self, _event: &ProgramEvent) -> Result<(), Box<dyn Error>> {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn evaluate_call_expression(
        &mut self,
        _call_expression: &str,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn current_step_id(&mut self) -> StepId {
        unreachable!("{ONLY_LOAD_EVENTS}")
    }
    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

/// A live recreator session over `events`, which the test extends to model
/// the running program writing more output.
fn live_handler(events: Arc<Mutex<Vec<ProgramEvent>>>) -> Handler {
    let args = RecreatorArgs {
        live_program: Some(PathBuf::from("/test/workdir/main")),
        ..RecreatorArgs::default()
    };
    Handler::construct_with_replay(
        TraceKind::Recreator,
        args,
        Arc::new(InMemoryTraceReader::new(Db::new(&PathBuf::from("/test/workdir")))),
        Box::new(GrowingEventLog { events }),
        false,
    )
}

fn contents(events: &Value) -> Vec<String> {
    rows(events).into_iter().map(|(content, _)| content).collect()
}

fn line_texts(answer: &Value) -> Vec<String> {
    answer["lines"]
        .as_array()
        .expect("lines")
        .iter()
        .map(|line| {
            line["segments"]
                .as_array()
                .expect("segments")
                .iter()
                .map(|s| s["content"].as_str().unwrap_or_default())
                .collect::<String>()
        })
        .filter(|text| !text.is_empty())
        .collect()
}

/// The program's later output reaches the terminal after `ct/event-load` has
/// seen it.
#[test]
fn a_live_terminal_follows_the_event_log_after_event_load() {
    let events = Arc::new(Mutex::new(vec![write_event(0, "first\n")]));
    let mut handler = live_handler(Arc::clone(&events));

    assert_eq!(contents(&load_terminal(&mut handler)), ["first\n"]);
    assert_eq!(line_texts(&load_terminal_lines(&mut handler)), ["first"]);

    events.lock().expect("event list").push(write_event(1, "second\n"));
    assert_eq!(contents(&event_load(&mut handler)["events"]), ["first\n", "second\n"]);

    assert_eq!(
        contents(&load_terminal(&mut handler)),
        ["first\n", "second\n"],
        "ct/load-terminal kept the terminal from before the program's later output"
    );
    assert_eq!(
        line_texts(&load_terminal_lines(&mut handler)),
        ["first", "second"],
        "ct/load-terminal-lines kept the lines from before the program's later output"
    );
}

/// Nor does the terminal wait for `ct/event-load`: a terminal request alone
/// shows what the live event log has now.
#[test]
fn a_live_terminal_follows_the_event_log_without_event_load() {
    let events = Arc::new(Mutex::new(vec![write_event(0, "first\n")]));
    let mut handler = live_handler(Arc::clone(&events));

    assert_eq!(line_texts(&load_terminal_lines(&mut handler)), ["first"]);
    assert_eq!(contents(&load_terminal(&mut handler)), ["first\n"]);

    events.lock().expect("event list").push(write_event(1, "second\n"));
    assert_eq!(line_texts(&load_terminal_lines(&mut handler)), ["first", "second"]);
    assert_eq!(contents(&load_terminal(&mut handler)), ["first\n", "second\n"]);
}
