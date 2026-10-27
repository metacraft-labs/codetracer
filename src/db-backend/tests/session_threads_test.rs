//! The DAP thread list a session advertises comes from each trace's own
//! process list.
//!
//! Spec reference: `codetracer-pm/spec/Trace-Files/Session-Manifest.md` §1
//! (every trace is opened through its single-trace `Handler` and multiplexed
//! behind one DAP thread space) and
//! `codetracer-pm/spec/Testing/Multi-Process-Multi-Thread-DAP-Integration-Tests.md`
//! "Overview" / "Category 1" (a fork recording is process-visible over DAP).
//!
//! ## What this pins
//!
//! 1. A session's `threads` list ([`SessionHandler::thread_list`]) and its
//!    `ct/listProcesses` payload ([`SessionHandler::process_list`]) carry one
//!    thread per recorded process of a multi-process trace — the process the
//!    worker replays as thread 1, every other one under its pid — the same
//!    rows the single-trace [`Handler::threads`] response carries, because
//!    both read [`Handler::collect_thread_descriptors`]. The replayed process
//!    falls back to the root for a worker that marks none, a non-replayed
//!    pid 1 is remapped off thread 1, and forked children are labelled with
//!    the executable they were forked from.
//! 2. A multi-trace session composes those pids with the trace slot and
//!    applies the manifest prefix.
//! 3. A trace without process metadata (synthetic pid-0 entry, empty list,
//!    or a failed query) still contributes exactly the legacy
//!    `(1, "<thread 1>")`.
//! 4. A pid that does not fit the 24-bit inner id budget is refused rather
//!    than silently routed to the wrong trace.
//!
//! Before the fix the session layer answered every trace with a hard-coded
//! `(1, "<thread 1>")` and never asked the trace, so a fork recording
//! surfaced one thread
//! (`codetracer-native-backend/tests/multiprocess_flow_test.rs::
//! test_rr_multiprocess_threads_visible`).
//!
//! ## Why a test double stands in for the replay session
//!
//! [`ProcessListReplay`] replaces the trace's `ReplaySession` and answers
//! only `list_processes`. The production answer for an rr trace comes from
//! the native replay worker running `rr ps` over a real fork recording, which
//! needs rr, perf counters and the `ct-native-replay` binary from the sibling
//! `codetracer-native-backend` repository. That full path is exercised end to
//! end by `test_rr_multiprocess_threads_visible` there. This file pins the
//! db-backend half — the projection and the session aggregation — so the
//! double supplies the worker's answer and nothing else; every other trait
//! method is unreachable here and panics if called.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::error::Error;
use std::path::PathBuf;
use std::sync::mpsc;

use codetracer_trace_types::StepId;
use db_backend::dap::{self, DapMessage};
use db_backend::dap_handler::{
    Handler, NON_REPLAYED_PID_1_THREAD_ID, process_thread_label, thread_descriptors_from_processes,
};
use db_backend::db::{Db, DbRecordEvent};
use db_backend::expr_loader::ExprLoader;
use db_backend::lang::Lang;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::replay::ReplaySession;
use db_backend::session_handler::{SessionHandler, SessionHandlerError, TRACE_SLOT_SHIFT};
use db_backend::session_manifest::{RecordingId, SessionManifest, TraceEntry};
use db_backend::task::{
    Action, Breakpoint, CallLine, CtLoadLocalsArguments, Events, HistoryResultWithRecord, LoadHistoryArg, Location,
    ProcessInfo, ProgramEvent, TraceKind, VariableWithRecord,
};
use db_backend::value::ValueRecordWithType;

/// What the double's `list_processes` answers.
#[derive(Debug)]
enum ProcessAnswer {
    Processes(Vec<ProcessInfo>),
    Failure(&'static str),
}

/// A `ReplaySession` that only knows the trace's process list. See the
/// module documentation for why it is a double.
#[derive(Debug)]
struct ProcessListReplay {
    answer: ProcessAnswer,
}

const ONLY_LIST_PROCESSES: &str = "ProcessListReplay answers list_processes only";

impl ReplaySession for ProcessListReplay {
    fn list_processes(&mut self) -> Result<Vec<ProcessInfo>, Box<dyn Error>> {
        match &self.answer {
            ProcessAnswer::Processes(processes) => Ok(processes.clone()),
            ProcessAnswer::Failure(message) => Err((*message).into()),
        }
    }

    fn load_location(&mut self, _expr_loader: &mut ExprLoader) -> Result<Location, Box<dyn Error>> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn run_to_entry(&mut self) -> Result<(), Box<dyn Error>> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn load_events(&mut self) -> Result<Events, Box<dyn Error>> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn step(&mut self, _action: Action, _forward: bool) -> Result<bool, Box<dyn Error>> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn load_locals(&mut self, _arg: CtLoadLocalsArguments) -> Result<Vec<VariableWithRecord>, Box<dyn Error>> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn load_value(
        &mut self,
        _expression: &str,
        _depth_limit: Option<usize>,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn load_return_value(
        &mut self,
        _depth_limit: Option<usize>,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn load_step_events(&mut self, _step_id: StepId, _exact: bool) -> Vec<DbRecordEvent> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn load_callstack(&mut self) -> Result<Vec<CallLine>, Box<dyn Error>> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn load_history(&mut self, _arg: &LoadHistoryArg) -> Result<(Vec<HistoryResultWithRecord>, i64), Box<dyn Error>> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn add_breakpoint(
        &mut self,
        _path: &str,
        _line: i64,
        _column: Option<i64>,
        _condition: Option<String>,
    ) -> Result<Breakpoint, Box<dyn Error>> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn delete_breakpoint(&mut self, _breakpoint: &Breakpoint) -> Result<bool, Box<dyn Error>> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn delete_breakpoints(&mut self) -> Result<bool, Box<dyn Error>> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn toggle_breakpoint(&mut self, _breakpoint: &Breakpoint) -> Result<Breakpoint, Box<dyn Error>> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn enable_breakpoints(&mut self) -> Result<(), Box<dyn Error>> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn disable_breakpoints(&mut self) -> Result<(), Box<dyn Error>> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn jump_to(&mut self, _step_id: StepId) -> Result<bool, Box<dyn Error>> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn jump_to_call(&mut self, _location: &Location) -> Result<Location, Box<dyn Error>> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn event_jump(&mut self, _event: &ProgramEvent) -> Result<bool, Box<dyn Error>> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn callstack_jump(&mut self, _depth: usize) -> Result<(), Box<dyn Error>> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn location_jump(&mut self, _location: &Location) -> Result<(), Box<dyn Error>> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn tracepoint_jump(&mut self, _event: &ProgramEvent) -> Result<(), Box<dyn Error>> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn evaluate_call_expression(
        &mut self,
        _call_expression: &str,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn current_step_id(&mut self) -> StepId {
        unreachable!("{ONLY_LIST_PROCESSES}")
    }
    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

/// The process table `rr ps` reports for the `m2_parent.c` fork fixture
/// (pids as `rr ps` reported them for one recording of that fixture).
const PARENT_PID: u32 = 4_071_167;
const CHILD_PID: u32 = 4_071_216;

fn process(pid: u32, ppid: u32, command: &str, replayed: bool) -> ProcessInfo {
    ProcessInfo {
        pid,
        ppid,
        exit_code: Some(0),
        command: command.to_string(),
        replayed,
    }
}

/// The fork recording as a worker reports it, with the process it replays
/// marked (`None`: a worker that predates the `replayed` field).
fn fork_processes(replayed: Option<u32>) -> Vec<ProcessInfo> {
    vec![
        process(
            PARENT_PID,
            0,
            "/build/test-binaries/m2_parent",
            replayed == Some(PARENT_PID),
        ),
        process(
            CHILD_PID,
            PARENT_PID,
            "(forked without exec)",
            replayed == Some(CHILD_PID),
        ),
    ]
}

fn parent_label() -> String {
    format!("m2_parent (pid {PARENT_PID})")
}

fn child_label() -> String {
    format!("m2_parent (pid {CHILD_PID}, forked from {PARENT_PID})")
}

fn handler_answering(answer: ProcessAnswer) -> Handler {
    let mut handler = Handler::new(
        TraceKind::Materialized,
        RecreatorArgs::default(),
        Box::new(Db::new(&PathBuf::from(""))),
    );
    handler.replay = Box::new(ProcessListReplay { answer });
    handler
}

fn single_trace_session(answer: ProcessAnswer) -> SessionHandler {
    let manifest = SessionManifest::single_trace(PathBuf::from("m2_parent/rr"));
    SessionHandler::new(manifest, vec![handler_answering(answer)]).expect("single-trace session")
}

fn trace_entry(recording_id: &str, prefix: &str) -> TraceEntry {
    TraceEntry {
        recording_id: RecordingId(recording_id.to_string()),
        path: PathBuf::from(format!("{recording_id}.ct")),
        role: "backend".to_string(),
        default_thread_prefix: prefix.to_string(),
    }
}

fn rows(session: &mut SessionHandler) -> Vec<(i64, String)> {
    session
        .thread_list()
        .expect("thread list")
        .into_iter()
        .map(|thread| (thread.composed_thread_id, thread.name))
        .collect()
}

fn projection(processes: Vec<ProcessInfo>) -> Vec<(u32, String)> {
    thread_descriptors_from_processes(Ok(processes))
}

fn legacy_single_thread() -> Vec<(i64, String)> {
    vec![(1, "<thread 1>".to_string())]
}

#[test]
fn a_fork_trace_session_lists_the_replayed_parent_as_thread_one() {
    let mut session = single_trace_session(ProcessAnswer::Processes(fork_processes(Some(PARENT_PID))));

    assert_eq!(
        rows(&mut session),
        vec![(1, parent_label()), (i64::from(CHILD_PID), child_label())]
    );

    let processes = session.process_list().expect("process list");
    assert_eq!(processes.len(), 1, "one process-tree row per trace");
    assert_eq!(processes[0].thread_count, 2);
    assert_eq!(processes[0].thread_ids, vec![1, i64::from(CHILD_PID)]);
}

#[test]
fn a_replay_targeted_at_the_child_makes_the_child_thread_one() {
    assert_eq!(
        projection(fork_processes(Some(CHILD_PID))),
        vec![(PARENT_PID, parent_label()), (1, child_label())]
    );
}

#[test]
fn a_worker_that_marks_nothing_has_its_root_process_treated_as_replayed() {
    // A worker that predates the `replayed` field: the reply parses with
    // every row unmarked, and the root (parent not in the recording) is the
    // process rr replays by default.
    let reply = serde_json::json!([
        {"pid": PARENT_PID, "ppid": 0, "exit_code": 0, "command": "/build/test-binaries/m2_parent"},
        {"pid": CHILD_PID, "ppid": PARENT_PID, "exit_code": 0, "command": "(forked without exec)"},
    ]);
    let processes: Vec<ProcessInfo> = serde_json::from_value(reply).expect("an old worker's reply parses");
    assert!(processes.iter().all(|info| !info.replayed));
    assert_eq!(
        projection(processes),
        vec![(1, parent_label()), (CHILD_PID, child_label())]
    );

    // The root is found by parentage, not by position.
    let mut reordered = fork_processes(None);
    reordered.reverse();
    assert_eq!(
        projection(reordered),
        vec![(CHILD_PID, child_label()), (1, parent_label())]
    );
}

#[test]
fn only_the_first_of_several_marked_processes_is_thread_one() {
    let mut processes = fork_processes(Some(CHILD_PID));
    processes[0].replayed = true;
    assert_eq!(
        projection(processes),
        vec![(1, parent_label()), (CHILD_PID, child_label())]
    );
}

#[test]
fn a_recorded_pid_1_that_is_not_replayed_does_not_collide_with_thread_one() {
    // A recording made inside a container, whose root is pid 1, replayed
    // with the worker targeted at the forked child.
    let processes = vec![
        process(1, 0, "/init", false),
        process(7, 1, "(forked without exec)", true),
    ];
    let threads = projection(processes);
    assert_eq!(
        threads,
        vec![
            (NON_REPLAYED_PID_1_THREAD_ID, "init (pid 1)".to_string()),
            (1, "init (pid 7, forked from 1)".to_string()),
        ]
    );
    // Remapped id still fits the session's inner id budget.
    let mut session = single_trace_session(ProcessAnswer::Processes(vec![
        process(1, 0, "/init", false),
        process(7, 1, "(forked without exec)", true),
    ]));
    assert_eq!(
        rows(&mut session),
        vec![
            (i64::from(NON_REPLAYED_PID_1_THREAD_ID), "init (pid 1)".to_string()),
            (1, "init (pid 7, forked from 1)".to_string()),
        ]
    );
    // When pid 1 is the replayed process, it simply is thread 1.
    assert_eq!(
        projection(vec![
            process(1, 0, "/init", true),
            process(7, 1, "(forked without exec)", false)
        ]),
        vec![
            (1, "init (pid 1)".to_string()),
            (7, "init (pid 7, forked from 1)".to_string())
        ]
    );
}

#[test]
fn forked_children_are_labelled_with_the_executable_they_were_forked_from() {
    let processes = vec![
        process(10, 0, "/opt/app/server --port 80", true),
        process(11, 10, "(forked without exec)", false),
        // A fork of a fork still runs the root's executable.
        process(12, 11, "(forked without exec)", false),
        // An exec'd child names its own executable.
        process(13, 10, "worker_cpp 10", false),
        // A fork whose parent is not in the recording names no executable.
        process(14, 99, "(forked without exec)", false),
    ];
    let labels: Vec<String> = processes
        .iter()
        .map(|info| process_thread_label(info, &processes))
        .collect();
    assert_eq!(
        labels,
        vec![
            "server (pid 10)",
            "server (pid 11, forked from 10)",
            "server (pid 12, forked from 11)",
            "worker_cpp (pid 13)",
            "process (pid 14, forked from 99)",
        ]
    );
}

#[test]
fn the_single_trace_threads_response_matches_the_session_thread_list() {
    let mut handler = handler_answering(ProcessAnswer::Processes(fork_processes(Some(PARENT_PID))));
    let (tx, rx) = mpsc::channel();
    let request = dap::Request {
        base: dap::ProtocolMessage {
            seq: 7,
            type_: "request".to_string(),
        },
        command: "threads".to_string(),
        arguments: serde_json::json!({}),
    };
    handler.threads(request, tx).expect("threads request");
    let DapMessage::Response(response) = rx.try_recv().expect("a threads response") else {
        panic!("expected a response");
    };
    let handler_rows: Vec<(i64, String)> = response.body["threads"]
        .as_array()
        .expect("threads array")
        .iter()
        .map(|thread| {
            (
                thread["id"].as_i64().expect("id"),
                thread["name"].as_str().expect("name").to_string(),
            )
        })
        .collect();

    let mut session = single_trace_session(ProcessAnswer::Processes(fork_processes(Some(PARENT_PID))));
    assert_eq!(handler_rows, rows(&mut session));
}

#[test]
fn a_fork_trace_in_a_later_slot_gets_composed_prefixed_thread_ids() {
    let manifest = SessionManifest {
        traces: vec![trace_entry("rec-frontend", "fe"), trace_entry("rec-native", "native")],
        ..SessionManifest::single_trace(PathBuf::from("unused"))
    };
    let mut session = SessionHandler::new(
        manifest,
        vec![
            handler_answering(ProcessAnswer::Processes(Vec::new())),
            handler_answering(ProcessAnswer::Processes(fork_processes(Some(PARENT_PID)))),
        ],
    )
    .expect("two-trace session");

    let slot_1 = 1i64 << TRACE_SLOT_SHIFT;
    assert_eq!(
        rows(&mut session),
        vec![
            (1, "fe:<thread 1>".to_string()),
            (slot_1 | 1, format!("native:{}", parent_label())),
            (slot_1 | i64::from(CHILD_PID), format!("native:{}", child_label())),
        ]
    );
    // Every advertised id routes back to the trace that reported it.
    assert!(
        session
            .handler_for_thread_id_mut(slot_1 | i64::from(CHILD_PID))
            .is_some()
    );
}

#[test]
fn a_trace_without_process_metadata_keeps_the_single_legacy_thread() {
    let synthetic = ProcessInfo {
        pid: 0,
        ppid: 0,
        exit_code: None,
        command: "main".to_string(),
        replayed: true,
    };
    for answer in [
        ProcessAnswer::Processes(vec![synthetic]),
        ProcessAnswer::Processes(Vec::new()),
        ProcessAnswer::Failure("worker refused GetProcessInfo"),
    ] {
        let mut session = single_trace_session(answer);
        assert_eq!(rows(&mut session), legacy_single_thread());
        let processes = session.process_list().expect("process list");
        assert_eq!(processes[0].thread_ids, vec![1]);
    }
}

#[test]
fn a_pid_beyond_the_inner_thread_budget_is_refused_not_misrouted() {
    let too_wide = 1u32 << TRACE_SLOT_SHIFT;
    let mut session = single_trace_session(ProcessAnswer::Processes(vec![
        process(10, 0, "/opt/app/server", true),
        process(too_wide, 10, "worker", false),
    ]));
    match session.thread_list() {
        Err(SessionHandlerError::ThreadIdOverflow { slot: 0, inner }) => assert_eq!(inner, too_wide),
        other => panic!("expected ThreadIdOverflow, got {other:?}"),
    }
}
