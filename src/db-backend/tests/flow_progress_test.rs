//! A flow walk reports how far it has got while it runs.
//!
//! The flow's answer is one `ct/updated-flow` event at the end of the walk,
//! and on a replay the walk can take tens of seconds. GPUI keeps a 30 s
//! per-message clock while its window opens, so a long first flow read as a
//! stalled engine and the window gave up (codetracer-pm
//! `issues/2026-11-18-replay-server-waits-on-a-flow-worker-that-died-after-connecting.md`,
//! 2026-11-19). The walk now reports `ct/flow-progress` at most once per
//! interval (2 s from `ct/load-flow`).
//!
//! No mocks: the recording is a real in-memory materialized trace served
//! through the production `MaterializedReplaySession`, walked by the
//! production `FlowPreloader::load`.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use codetracer_trace_types::{
    CallKey, FullValueRecord, FunctionId, FunctionRecord, Line, PathId, StepId, TypeId, TypeKind, TypeRecord,
    TypeSpecificInfo, ValueRecord, VariableId,
};
use db_backend::dap::DapMessage;
use db_backend::dap_handler::flow_progress_event;
use db_backend::db::{Db, DbCall, DbStep, EndOfProgram, MaterializedReplaySession};
use db_backend::flow_preloader::{FlowPreloader, FlowProgress};
use db_backend::in_memory_trace_reader::InMemoryTraceReader;
use db_backend::task::{FlowMode, Location, RRTicks, TraceKind};
use db_backend::trace_reader::TraceReader;

/// A three-line function: the walk visits one step per line.
const SOURCE: &str = "def main():
    total = compute(2)
    label = \"done\"
    print(label)
";
const ASSIGN_LINE: i64 = 2;
const NEXT_LINE: i64 = 3;
const LAST_LINE: i64 = 4;

/// One recorded step: its id, its line, and the `(variable, value)` pairs.
type RecordedStep = (i64, i64, Vec<(&'static str, i64)>);

/// What the recorder recorded at each step. `total` first exists at the step
/// AFTER its assignment line, which is how a line-level recorder records an
/// assignment.
fn recorded_steps() -> Vec<RecordedStep> {
    vec![
        (0, ASSIGN_LINE, vec![]),
        (1, NEXT_LINE, vec![("total", 4)]),
        (2, LAST_LINE, vec![("total", 4), ("label", 7)]),
    ]
}

fn build_reader(trace_dir: &Path, recorded: &Path) -> Arc<dyn TraceReader> {
    let recorded_str = recorded.display().to_string();
    let mut db = Db::new(&trace_dir.to_path_buf());

    db.paths.push(String::new());
    db.paths.push(recorded_str.clone());
    db.register_path_version(recorded_str, PathId(1));

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

    let mut names: Vec<&str> = Vec::new();
    let mut path1_map: HashMap<usize, Vec<DbStep>> = HashMap::new();
    for (id, line, vars) in recorded_steps() {
        let step = DbStep {
            step_id: StepId(id),
            path_id: PathId(1),
            line: Line(line),
            column: None,
            call_key,
            global_call_key: call_key,
        };
        db.steps.push(step);
        let mut values = Vec::new();
        for (name, value) in vars {
            let id = names.iter().position(|n| *n == name).unwrap_or_else(|| {
                names.push(name);
                names.len() - 1
            });
            values.push(FullValueRecord {
                variable_id: VariableId(id),
                value: ValueRecord::Int {
                    i: value,
                    type_id: TypeId(0),
                },
            });
        }
        db.variables.push(values);
        db.instructions.push(Vec::new());
        db.compound.push(HashMap::new());
        db.cells.push(HashMap::new());
        db.variable_cells.push(HashMap::new());
        path1_map.entry(line as usize).or_default().push(step);
    }
    for name in names {
        db.variable_names.push(name.to_string());
    }
    db.step_map.push(HashMap::new());
    db.step_map.push(path1_map);
    db.end_of_program = EndOfProgram::Normal;

    Arc::new(InMemoryTraceReader::new(db))
}

/// Walk the flow of `main` with `flow_preloader`, reporting progress at most
/// once per `every`, and return the reports in the order they were made.
fn walk_reporting_every(every: Duration) -> Vec<FlowProgress> {
    let dir = scratch_dir();
    let recorded = dir.join("main.py");
    std::fs::write(&recorded, SOURCE).expect("write source");
    let reader = build_reader(&dir, &recorded);
    let path = recorded.display().to_string();
    let location = Location {
        path: path.clone(),
        high_level_path: path,
        line: ASSIGN_LINE,
        high_level_line: ASSIGN_LINE,
        rr_ticks: RRTicks(0),
        ..Location::default()
    };
    let reports = Arc::new(Mutex::new(Vec::new()));
    let sink = Arc::clone(&reports);
    let mut flow_preloader = FlowPreloader::new();
    flow_preloader.report_progress(every, move |progress| sink.lock().unwrap().push(progress));
    let mut replay = MaterializedReplaySession::new(Arc::clone(&reader));
    let flow = flow_preloader.load(location, FlowMode::Call, TraceKind::Materialized, &mut replay);
    assert!(!flow.error, "the walk itself must succeed: {}", flow.error_message);
    let _ = std::fs::remove_dir_all(&dir);
    reports.lock().unwrap().clone()
}

fn scratch_dir() -> PathBuf {
    let dir = PathBuf::from(format!(
        "{}/test-traces/flow_progress_{}",
        env!("CARGO_MANIFEST_DIR"),
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("mkdir");
    dir
}

#[test]
fn a_walk_reports_its_steps_as_it_goes() {
    let reports = walk_reporting_every(Duration::ZERO);
    let walked: Vec<i64> = reports.iter().map(|report| report.steps_walked).collect();
    assert!(
        !walked.is_empty(),
        "a walk told to report at every step reported nothing"
    );
    assert!(
        walked.windows(2).all(|pair| pair[0] < pair[1]),
        "each report must count more walked steps than the one before: {walked:?}"
    );
    assert!(
        *walked.last().unwrap() <= recorded_steps().len() as i64,
        "the walk reported more steps than the recording holds: {walked:?}"
    );
}

#[test]
fn a_walk_shorter_than_the_interval_reports_nothing() {
    let reports = walk_reporting_every(Duration::from_secs(3600));
    assert!(
        reports.is_empty(),
        "a walk of a few ms reported {reports:?} on an hour's interval"
    );
}

#[test]
fn the_progress_event_names_the_steps_and_the_time() {
    let DapMessage::Event(event) = flow_progress_event(FlowProgress {
        steps_walked: 120,
        elapsed_ms: 4100,
    }) else {
        panic!("ct/flow-progress must be an event");
    };
    assert_eq!(event.event, "ct/flow-progress");
    assert_eq!(event.body, serde_json::json!({ "stepsWalked": 120, "elapsedMs": 4100 }));
}
