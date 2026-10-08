//! A flow line's AFTER values are read from the trace at the next step, for
//! every variable that line mentions — not only for the ones the next line's
//! source also happens to mention.
//!
//! `x = compute(2)` followed by a line that does not mention `x` is the common
//! case: the value `x` was assigned exists only after the line ran, and the
//! next line is the first step at which the recording holds it. The flow used
//! to fill a line's after values from the values it loaded for the NEXT line's
//! names, so `x` was dropped there and the assignment never showed its result.
//!
//! No mocks: the recording is a real in-memory materialized trace served
//! through the production `MaterializedReplaySession`, and the flow is the
//! production `FlowPreloader::load`.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use codetracer_trace_types::{
    CallKey, FullValueRecord, FunctionId, FunctionRecord, Line, PathId, StepId, TypeId, TypeKind, TypeRecord,
    TypeSpecificInfo, ValueRecord, VariableId,
};
use db_backend::db::{Db, DbCall, DbStep, EndOfProgram, MaterializedReplaySession};
use db_backend::flow_preloader::FlowPreloader;
use db_backend::in_memory_trace_reader::InMemoryTraceReader;
use db_backend::task::{FlowMode, FlowUpdate, Location, RRTicks, TraceKind};
use db_backend::trace_reader::TraceReader;

/// Line 2 assigns `total` from a call; line 3 does not mention it; line 4 uses
/// `label` only. Line numbers are asserted against the text below.
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

fn load_flow(recorded: &Path, reader: Arc<dyn TraceReader>) -> FlowUpdate {
    let path = recorded.display().to_string();
    let location = Location {
        path: path.clone(),
        high_level_path: path,
        line: ASSIGN_LINE,
        high_level_line: ASSIGN_LINE,
        rr_ticks: RRTicks(0),
        ..Location::default()
    };
    let mut flow_preloader = FlowPreloader::new();
    let mut replay = MaterializedReplaySession::new(Arc::clone(&reader));
    flow_preloader.load(location, FlowMode::Call, TraceKind::Materialized, &mut replay)
}

fn scratch_dir() -> PathBuf {
    let dir = PathBuf::from(format!(
        "{}/test-traces/flow_after_values_{}",
        env!("CARGO_MANIFEST_DIR"),
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("mkdir");
    dir
}

#[test]
fn an_assignment_shows_its_value_when_the_next_line_does_not_mention_it() {
    let lines: Vec<&str> = SOURCE.lines().collect();
    assert!(lines[(ASSIGN_LINE - 1) as usize].contains("total = compute(2)"));
    assert!(!lines[(NEXT_LINE - 1) as usize].contains("total"));

    let dir = scratch_dir();
    let recorded = dir.join("after_values.py");
    std::fs::write(&recorded, SOURCE).expect("write source");
    let update = load_flow(&recorded, build_reader(&dir, &recorded));
    let _ = std::fs::remove_dir_all(&dir);
    assert!(!update.error, "flow update errored: {}", update.error_message);

    let view = &update.view_updates[0];
    let lines_walked: Vec<i64> = view.steps.iter().map(|s| s.position.0).collect();
    assert_eq!(
        lines_walked,
        vec![ASSIGN_LINE, NEXT_LINE, LAST_LINE],
        "the flow walks the three recorded lines"
    );

    let assign = &view.steps[0];
    assert!(
        assign.expr_order.iter().any(|e| e == "total"),
        "the assignment line names `total`: {:?}",
        assign.expr_order
    );
    let after = assign.after_values.get("total").unwrap_or_else(|| {
        panic!(
            "the assignment line has no after value for `total`; after_values = {:?}",
            assign.after_values
        )
    });
    assert_eq!(
        after.i, "4",
        "`total` after line {ASSIGN_LINE} is what the next step recorded"
    );

    // `label` is assigned on line 3 and used on line 4, so it was already
    // covered; it still is, with the same value.
    let next = &view.steps[1];
    assert_eq!(next.after_values.get("label").map(|v| v.i.as_str()), Some("7"));
}
