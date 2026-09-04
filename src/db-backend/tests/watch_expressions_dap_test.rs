//! Watch expressions answered over `ct/load-locals`, end to end.
//!
//! # What this guards that the unit tests do not
//!
//! `watch_expression.rs`'s own tests cover the parser and the walk over
//! `ValueRecordWithType`. They cannot see any of the wiring that carries
//! an expression from the wire to that walk and the answer back out, and
//! that wiring is where the feature was broken: `Db::load_locals` took
//! `watch_expressions` off the request and dropped it with a `warn!`, so
//! every one of those unit tests could have passed — and did not exist —
//! while the product answered nothing.
//!
//! So everything here goes through the real `ct/load-locals` request:
//! `Handler::load_locals` -> `Db::load_locals` -> the evaluator -> the
//! serialized DAP response. What is asserted is what a frontend receives.
//!
//! # Why the trace is built by hand
//!
//! The interesting cases are a struct with named fields and an indexed
//! sequence, at a step where a specific element has a specific value.
//! Recording one would make this suite depend on a recorder sibling for
//! a contract that has nothing to do with recording. This uses the same
//! `InMemoryTraceReader` escape hatch `javascript_locals_dap_test.rs`
//! documents: no behaviour is stubbed, the real `Db`/`Handler` path runs,
//! and only the trace *data* stands in for a recorder.
//!
//! # The shape of every assertion here
//!
//! A NAMED expression with a KNOWN value, never an existential. `xs[1]`
//! is 2000 while `xs[0]` is 100 and the whole sequence contains both, so
//! an implementation that answered with the sequence, the wrong element,
//! or by name-matching the expression against the locals list cannot
//! satisfy it. And the refusals are asserted on their TEXT: a watch that
//! cannot be answered must produce a row carrying a reason, because a
//! pane whose two states are "a value" and "nothing" is the defect this
//! whole change exists to remove.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::mpsc;

use codetracer_trace_types::{
    CallKey, FieldTypeRecord, FullValueRecord, FunctionId, FunctionRecord, Line as TraceLine, NO_KEY, PathId, StepId,
    TypeId, TypeKind, TypeRecord, TypeSpecificInfo, ValueRecord, VariableId,
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

/// The recorded values this suite asserts against.
///
/// Named constants rather than literals in the assertions so the trace
/// and the expectations cannot drift apart silently.
const SHIELD: i64 = 10_000;
const MASSES: [i64; 4] = [100, 2000, 200, 14];
const POINT_X: i64 = 3;
const POINT_Y: i64 = 7;

/// One row of a `ct/load-locals` response, reduced to what is asserted.
#[derive(Debug, Clone)]
struct Row {
    /// The `expression` the row was reported under.
    name: String,
    /// The rendered text of the value (`Value`'s `i`/`text`/`msg`).
    text: String,
    /// Whether the backend marked this row as a watch answer.
    is_watch: bool,
}

/// Every row a request answered with, in wire order.
///
/// A `Vec` and not a map keyed by expression, and that is load-bearing:
/// watching `initial_shield` when a LOCAL of that name exists is the most
/// ordinary watch anyone types, and it correctly produces TWO rows — the
/// recorded local and the watch answer. A map keyed by expression silently
/// collapses them to one, which is how a test would fail to notice that
/// the locals dedup had eaten the watch (the reason watches are appended
/// after `dedup_by` in `Db::load_locals`).
#[derive(Debug)]
struct Rows(Vec<Row>);

impl Rows {
    /// The one non-watch row named `name`.
    fn local(&self, name: &str) -> &Row {
        self.one(name, false)
    }

    /// The one watch row for `expression`.
    fn watch(&self, expression: &str) -> &Row {
        self.one(expression, true)
    }

    fn one(&self, name: &str, is_watch: bool) -> &Row {
        let matches: Vec<&Row> = self
            .0
            .iter()
            .filter(|r| r.name == name && r.is_watch == is_watch)
            .collect();
        let kind = if is_watch { "watch" } else { "local" };
        assert_eq!(
            matches.len(),
            1,
            "expected exactly one {kind} row named `{name}`, found {}: {self:?}",
            matches.len()
        );
        matches[0]
    }

    fn watch_count(&self) -> usize {
        self.0.iter().filter(|r| r.is_watch).count()
    }

    fn has_local(&self, name: &str) -> bool {
        self.0.iter().any(|r| r.name == name && !r.is_watch)
    }
}

/// A trace with one step carrying a scalar, a sequence and a struct.
///
/// Deliberately a single step: the question under test is what a watch
/// resolves to AT a step, and adding more steps would let a defect that
/// answers from the wrong one hide behind a coincidence.
fn trace_with_a_scalar_a_sequence_and_a_struct() -> (Db, TempDir) {
    const SOURCE_PATH: &str = "main.nr";
    const SOURCE: &str = "fn main() {\n  let shield = 10000;\n}\n";

    let workdir_holder = tempfile::tempdir().expect("tempdir");
    let workdir = workdir_holder.path().to_path_buf();
    std::fs::write(workdir.join(SOURCE_PATH), SOURCE).expect("write source");

    let mut db = Db::new(&workdir);
    db.paths.push(String::new());
    db.paths.push(SOURCE_PATH.to_string());
    db.path_map.insert(SOURCE_PATH.to_string(), PathId(1));
    db.path_map
        .insert(workdir.join(SOURCE_PATH).to_string_lossy().to_string(), PathId(1));

    // TypeId(0) int, TypeId(1) sequence, TypeId(2) the struct.
    db.types.push(TypeRecord {
        kind: TypeKind::Int,
        lang_type: "Field".to_string(),
        specific_info: TypeSpecificInfo::None,
    });
    db.types.push(TypeRecord {
        kind: TypeKind::Seq,
        lang_type: "[Field; 4]".to_string(),
        specific_info: TypeSpecificInfo::None,
    });
    db.types.push(TypeRecord {
        kind: TypeKind::Struct,
        lang_type: "Point".to_string(),
        specific_info: TypeSpecificInfo::Struct {
            fields: vec![
                FieldTypeRecord {
                    name: "x".to_string(),
                    type_id: TypeId(0),
                },
                FieldTypeRecord {
                    name: "y".to_string(),
                    type_id: TypeId(0),
                },
            ],
        },
    });

    db.functions.push(FunctionRecord {
        path_id: PathId(1),
        line: TraceLine(1),
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
        parent_key: NO_KEY,
        children_keys: Vec::new(),
    });

    let name_id = |db: &mut Db, name: &str| -> VariableId {
        let id = VariableId(db.variable_names.len());
        db.variable_names.push(name.to_string());
        id
    };
    let shield_id = name_id(&mut db, "initial_shield");
    let masses_id = name_id(&mut db, "asteroid_masses");
    let point_id = name_id(&mut db, "landing_point");

    let step = DbStep {
        step_id: StepId(0),
        path_id: PathId(1),
        line: TraceLine(2),
        column: None,
        call_key,
        global_call_key: call_key,
    };
    db.steps.push(step);
    let mut step_map_for_path: HashMap<usize, Vec<DbStep>> = HashMap::new();
    step_map_for_path.entry(2).or_default().push(step);

    let int = |i: i64| ValueRecord::Int { i, type_id: TypeId(0) };
    db.variables.push(vec![
        FullValueRecord {
            variable_id: shield_id,
            value: int(SHIELD),
        },
        FullValueRecord {
            variable_id: masses_id,
            value: ValueRecord::Sequence {
                elements: MASSES.iter().copied().map(int).collect(),
                is_slice: false,
                type_id: TypeId(1),
            },
        },
        FullValueRecord {
            variable_id: point_id,
            value: ValueRecord::Struct {
                field_values: vec![int(POINT_X), int(POINT_Y)],
                type_id: TypeId(2),
            },
        },
    ]);
    db.instructions.push(Vec::new());
    db.compound.push(HashMap::new());
    db.cells.push(HashMap::new());
    db.variable_cells.push(HashMap::new());

    db.step_map.push(HashMap::new());
    db.step_map.push(step_map_for_path);
    db.end_of_program = EndOfProgram::Normal;

    (db, workdir_holder)
}

fn handler_with_trace(db: Db) -> Handler {
    let reader: Arc<dyn db_backend::trace_reader::TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false)
}

/// Render a wire `Value` the way a frontend does.
///
/// `text_representation.nim` dispatches per `TypeKind`; the three kinds
/// this suite produces are Int (`i`), String (`text`) and Error (`msg`).
/// Reading whichever is populated is what makes a refusal comparable to
/// a value: both arrive as one row and the pane shows one string.
fn render(value: &JsonValue) -> String {
    for field in ["msg", "i", "text", "r"] {
        if let Some(s) = value.get(field).and_then(JsonValue::as_str)
            && !s.is_empty()
        {
            return s.to_string();
        }
    }
    // A compound value has no scalar field; report its shape so a failure
    // can say "you got the whole sequence" rather than "you got nothing".
    if let Some(elements) = value.get("elements").and_then(JsonValue::as_array)
        && !elements.is_empty()
    {
        return format!("[{}]", elements.iter().map(render).collect::<Vec<String>>().join(", "));
    }
    String::new()
}

/// Drive one `ct/load-locals` with `watches`, and return every row it
/// answered with, keyed by expression.
fn load_locals_with_watches(handler: &mut Handler, watches: &[&str]) -> Rows {
    handler.step_id = StepId(0);
    handler.replay.jump_to(StepId(0)).expect("jump_to");

    let (tx, rx) = mpsc::channel::<DapMessage>();
    let arguments = serde_json::json!({
        "rrTicks": 0,
        "countBudget": 1000,
        "minCountLimit": 0,
        "lang": Lang::Noir as u8,
        "watchExpressions": watches,
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

    // EXPORT THE RESPONSE BYTES, for the browser probe to render.
    //
    // `ci/test/watch_expressions_browser_probe.nim` mounts the real State
    // panel in a real browser over this JSON. Capturing it HERE rather
    // than hand-writing a fixture is the whole point: what the pane is
    // asked to render is then what this backend actually emitted, and it
    // cannot drift from the backend without this suite noticing.
    if let Ok(dir) = std::env::var("CT_WRITE_WATCH_FIXTURE") {
        let key = watches.join("|").replace(['/', ' '], "_");
        let path = std::path::Path::new(&dir).join(format!("{key}.json"));
        std::fs::create_dir_all(&dir).expect("fixture dir");
        std::fs::write(&path, serde_json::to_string_pretty(&body).expect("serialize")).expect("write fixture");
    }

    Rows(
        body.get("locals")
            .and_then(JsonValue::as_array)
            .expect("locals array")
            .iter()
            .map(|local| {
                let name = local
                    .get("expression")
                    .and_then(JsonValue::as_str)
                    .expect("expression")
                    .to_string();
                let value = local.get("value").cloned().unwrap_or(JsonValue::Null);
                let is_watch = value.get("isWatch").and_then(JsonValue::as_bool).unwrap_or(false);
                Row {
                    name,
                    text: render(&value),
                    is_watch,
                }
            })
            .collect(),
    )
}

/// The locals themselves must be unaffected by asking for watches.
///
/// Asserted FIRST and separately: if the request answered nothing at all
/// every check below would fail for one reason, and the report would not
/// say whether watches were broken or the whole response was.
#[test]
fn the_locals_still_arrive_and_are_not_marked_as_watches() {
    let (db, _tmp) = trace_with_a_scalar_a_sequence_and_a_struct();
    let mut handler = handler_with_trace(db);
    let rows = load_locals_with_watches(&mut handler, &["initial_shield"]);

    let shield = rows.local("initial_shield");
    assert_eq!(shield.text, SHIELD.to_string(), "rows: {rows:?}");
    assert!(
        rows.has_local("asteroid_masses") && rows.has_local("landing_point"),
        "every recorded local must still be reported: {rows:?}"
    );
    // AND THE WATCH IS A SECOND, SEPARATE ROW. Watching a name that is
    // also a local must not replace the local or be replaced by it --
    // `Db::load_locals` dedups locals by expression, so a watch appended
    // before that dedup would have been deleted by it.
    let watch = rows.watch("initial_shield");
    assert_eq!(watch.text, SHIELD.to_string(), "rows: {rows:?}");
    assert_eq!(
        rows.0.len(),
        4,
        "three locals and one watch answer, all reported: {rows:?}"
    );
}

/// A bare name resolves, and is marked so the pane can file it.
#[test]
fn a_bare_name_watch_is_answered_and_marked() {
    let (db, _tmp) = trace_with_a_scalar_a_sequence_and_a_struct();
    let mut handler = handler_with_trace(db);
    // A watch whose expression equals a local's name is the most ordinary
    // one anyone types, and it is exactly the row the locals dedup would
    // have deleted had watches been appended before it.
    let rows = load_locals_with_watches(&mut handler, &["initial_shield"]);
    assert_eq!(rows.watch_count(), 1, "exactly one watch answer: {rows:?}");
    let watch = rows.watch("initial_shield");
    assert_eq!(
        watch.text,
        SHIELD.to_string(),
        "the watch must carry the recorded value: {rows:?}"
    );
}

/// THE DISCRIMINATING CASE: an indexed element, not the sequence.
#[test]
fn an_indexed_watch_answers_with_that_element_only() {
    let (db, _tmp) = trace_with_a_scalar_a_sequence_and_a_struct();
    let mut handler = handler_with_trace(db);
    let rows = load_locals_with_watches(&mut handler, &["asteroid_masses[1]"]);

    assert_eq!(
        rows.watch_count(),
        1,
        "the indexed watch produced no row at all -- the silent-drop defect: {rows:?}"
    );
    let watch = rows.watch("asteroid_masses[1]");
    assert_eq!(
        watch.text,
        MASSES[1].to_string(),
        "an indexed watch must answer with THAT element: {rows:?}"
    );
    // Not the whole sequence, and not a neighbour. `MASSES[0]` is 100 and
    // the rendered sequence contains it, so this is what separates "the
    // element" from "the container the element is in".
    assert!(
        !watch.text.contains(&MASSES[0].to_string()),
        "the watch answered with more than the element it named: {rows:?}"
    );
}

/// A named field of a recorded struct.
#[test]
fn a_field_watch_answers_with_that_field() {
    let (db, _tmp) = trace_with_a_scalar_a_sequence_and_a_struct();
    let mut handler = handler_with_trace(db);
    let rows = load_locals_with_watches(&mut handler, &["landing_point.y"]);
    assert_eq!(rows.watch_count(), 1, "the field watch produced no row: {rows:?}");
    let watch = rows.watch("landing_point.y");
    assert_eq!(watch.text, POINT_Y.to_string(), "rows: {rows:?}");
    assert_ne!(
        watch.text,
        POINT_X.to_string(),
        "`.y` answered with `.x` -- fields are being read positionally without their names: {rows:?}"
    );
}

/// THE REFUSAL PATH — a row, with a reason, never an absence.
///
/// This is the arm that separates "the feature works" from "the pane has
/// two states, a value and nothing". Each refusal is asserted on the text
/// a user would read, not merely on the row existing.
#[test]
fn every_unanswerable_watch_produces_a_row_carrying_its_reason() {
    let (db, _tmp) = trace_with_a_scalar_a_sequence_and_a_struct();
    let mut handler = handler_with_trace(db);
    let rows = load_locals_with_watches(
        &mut handler,
        &[
            "initial_shield + 1",
            "no_such_variable",
            "landing_point.z",
            "asteroid_masses[99]",
            "initial_shield[0]",
        ],
    );

    // Arithmetic: a recording holds what was recorded.
    let arith = rows.watch("initial_shield + 1");
    assert!(
        arith.text.contains("only holds the values that were actually recorded"),
        "the refusal must say why a recording cannot answer it, got: {}",
        arith.text
    );

    // A name that was never recorded at this step.
    let missing = rows.watch("no_such_variable");
    assert!(
        missing
            .text
            .contains("no variable named `no_such_variable` was recorded at this step"),
        "got: {}",
        missing.text
    );

    // An unknown field must list the fields that DO exist -- the
    // difference between a pane that says no and one that helps.
    let bad_field = rows.watch("landing_point.z");
    assert!(bad_field.text.contains("no field `z`"), "got: {}", bad_field.text);
    assert!(
        bad_field.text.contains("x, y"),
        "the refusal must name the fields that exist, got: {}",
        bad_field.text
    );

    // An out-of-range index must report how many WERE recorded, because
    // "not found" alone cannot be told apart from a wrong name.
    let oob = rows.watch("asteroid_masses[99]");
    assert!(oob.text.contains("past the end"), "got: {}", oob.text);
    assert!(
        oob.text.contains(&format!("{} element(s)", MASSES.len())),
        "the refusal must report the recorded length, got: {}",
        oob.text
    );

    // Indexing a scalar is refused BY SHAPE, naming what it found.
    let not_indexable = rows.watch("initial_shield[0]");
    assert!(
        not_indexable.text.contains("an integer") && not_indexable.text.contains("not indexable"),
        "got: {}",
        not_indexable.text
    );

    // AND THE COUNT. Five expressions in, five watch rows out -- so a
    // future change that answers four of them and drops one fails here
    // rather than in whichever assertion happened to name the dropped one.
    assert_eq!(
        rows.watch_count(),
        5,
        "every watch expression must produce exactly one row: {rows:?}"
    );
}

/// A watch that resolves and one that does not, in the same request.
///
/// The mixed case is its own test because the two arms share a loop: an
/// implementation that stopped at the first refusal, or that dropped the
/// working answers once a refusal appeared, passes both single-arm tests
/// above and fails a real pane.
#[test]
fn a_refusal_does_not_cost_the_watches_that_resolve_their_rows() {
    let (db, _tmp) = trace_with_a_scalar_a_sequence_and_a_struct();
    let mut handler = handler_with_trace(db);
    let rows = load_locals_with_watches(
        &mut handler,
        &["asteroid_masses[1]", "initial_shield + 1", "landing_point.x"],
    );

    assert_eq!(rows.watch_count(), 3, "three expressions, three rows: {rows:?}");
    assert_eq!(
        rows.watch("asteroid_masses[1]").text,
        MASSES[1].to_string(),
        "a refusal beside it must not cost a resolving watch its answer: {rows:?}"
    );
    assert_eq!(
        rows.watch("landing_point.x").text,
        POINT_X.to_string(),
        "a watch AFTER a refusal must still be answered: {rows:?}"
    );
    assert!(
        rows.watch("initial_shield + 1").text.contains("cannot evaluate"),
        "the refusal must still be reported: {rows:?}"
    );
}
